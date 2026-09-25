"""Find every client API a Lua file reads, and whether each read handles absence.

This is the extraction half of the client API availability gate
(`tooling.validation.flavour_api`); that module decides which of the names
found here each client flavour provides. This one works on the syntax tree
from `tooling.validation.lua_syntax` and answers two questions per file:

1. **Which host names does the file reach?** A Kit reaches the client in a
   small number of ways, all of which are recognised:

   - a free (global) name, such as `pairs` or `string` in `string.format`;
   - a read through the global table: `rawget(_G, "CreateFrame")`, `_G.X`,
     `_G["X"]`, or a local alias of `_G`;
   - a call to a *reader helper*: any local function of the file that
     performs one of those reads on one of its own parameters
     (`readGlobal(name)`, `readHostFunction(name)`,
     `readNamespaceFunction(namespace, name)`), directly or through another
     helper. Helpers are discovered by analysing their bodies, not listed, so a
     new Kit's helper is covered without configuration. A string constant held
     in a never-reassigned local (`local PROJECT_ID_GLOBAL = "WOW_PROJECT_ID"`)
     counts as the literal;
   - a field of a value obtained that way (`C_Timer.After`, `rawget(chatInfo,
     "SendAddonMessage")`, `Enum.ChatType`), recorded as a dotted member name;
   - a widget method: a `receiver:Method()` call, or a `receiver.Method` field
     read, whose name is a script-object method in the captured documentation
     (the caller passes that set);
   - an event name: a string literal equal to an event the documentation
     names, or any UPPER_SNAKE literal given to an event registration method.

   A read whose name cannot be computed statically (`readGlobal("SLASH_" ..
   key)`) is recorded as a *dynamic* reference: its availability cannot be
   checked, so the gate accepts it only when it is guarded.

2. **Is every use of the value protected against absence?** A value read from
   the host is *used* when it is called, indexed, operated on, or escapes to
   code this analysis does not follow (passed as an argument, returned, stored
   in a table). A use is *protected* when a test that proves the value present
   dominates it:

   - `if type(x) == "function" then ... x() ... end`, `if x then`,
     `if x ~= nil then`, and any conjunction containing such a test;
   - `x and x()`, `type(x) == "function" and x()`;
   - an early exit: `if type(x) ~= "function" then return end` (or `error`,
     `break`, or a disjunction containing such a test) protects what follows;
   - an assignment of a value that is certainly not `nil` (`x = fallback`
     where `fallback` is a function, table, string or number literal);
   - `pcall(x, ...)` and `xpcall(x, ...)`, which turn an absent function into a
     reported failure.

   A read whose only appearance is inside such a test (`type(readGlobal("X"))
   == "table"`, `readNamespaceFunction(...) ~= false`) is a probe and needs no
   further protection. `a or b` makes `b` an alternative to `a`: the use is
   satisfied on a flavour that provides either.

The analysis is flow-sensitive within a function and deliberately
conservative across functions: facts never cross into a nested function body
(a closure can run later, when they no longer hold), facts about a variable
die when it is reassigned, and a loop body starts without the facts the loop
itself could invalidate. A use it cannot prove protected is reported as
unguarded; the gate's allow-list exists for exactly the cases a human can
prove and this analysis cannot (a test stored in a boolean first, a guard in
another function). Known limits, stated in `docs/TOOLING.md`:

- a table mutated through a call (`frame.Method = nil` inside a callee) is not
  seen to invalidate facts about it;
- method receivers are not typed: `x:SetFixedFrameStrata()` is a widget method
  reference whatever `x` is, and a Kit object that defines a method of the
  same name is still reported (and needs an allow-list entry if the method is
  missing somewhere);
- event names built at run time, and events passed through variables other
  than never-reassigned string constants, are not seen.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable

from tooling.validation import lua_syntax as syntax


#: Kinds of reference.
KIND_GLOBAL = "global"
KIND_MEMBER = "member"
KIND_METHOD = "method"
KIND_EVENT = "event"
KIND_DYNAMIC = "dynamic"

#: Methods whose first argument is an event name: EventKit's connection API
#: and the frame's own registration methods.
EVENT_REGISTRATION_METHODS = frozenset(
    {
        "Connect",
        "Once",
        "ConnectUnit",
        "OnceUnit",
        "RegisterEvent",
        "RegisterUnitEvent",
        "UnregisterEvent",
        "IsEventRegistered",
    }
)

#: What an event name looks like.
EVENT_NAME_RE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$|^[A-Z]{4,}$")

#: The global table's name.
GLOBAL_TABLE = "_G"

#: Built-in functions whose arguments never escape: they only inspect them.
INSPECTING_BUILTINS = frozenset({"type", "tostring", "rawequal", "select"})

#: Built-in functions that call their first argument in protected mode.
PROTECTED_CALLERS = frozenset({"pcall", "xpcall"})

#: Lua 5.1's string library: a colon call of one of these on a host value is a
#: call through the string metatable, not a lookup in a client table. No client
#: namespace or widget has methods with these lower-case names.
STRING_METHODS = frozenset(
    {"byte", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "sub", "upper"}
)

#: A placeholder for a helper's parameter inside a template name: `{0}`.
_PLACEHOLDER_RE = re.compile(r"\{(\d+)\}")

#: Upper bound on analysis rounds; each round can only add information, so
#: the results settle long before this in practice.
_MAX_ROUNDS = 8


@dataclass
class Use:
    """One unprotected use of a host value.

    `alternatives` are the names any one of which, if present, makes the use
    safe: the reference itself plus whatever `or` offered as a fallback.
    """

    line: int
    reason: str
    alternatives: tuple[str, ...]


@dataclass
class Reference:
    """One place a file reaches one host name."""

    file: str
    line: int
    column: int
    kind: str
    name: str
    #: The reader helper the name went through, or `None` for a direct read.
    via: str | None = None
    #: Uses of the value that no test protects. Empty means guarded (or, for a
    #: name every flavour provides, simply safe).
    unguarded_uses: list[Use] = field(default_factory=list)
    #: Lines of the tests that protect the value, for the report.
    guard_lines: list[int] = field(default_factory=list)

    @property
    def guarded(self) -> bool:
        """Whether every use of the value is protected against absence."""
        return not self.unguarded_uses

    @property
    def location(self) -> str:
        return f"{self.file}:{self.line}"


# Symbols and scopes ------------------------------------------------------------


@dataclass(eq=False)
class Symbol:
    """One local variable (or parameter) declaration."""

    name: str
    line: int
    #: The function whose parameter this is, and its position, if it is one.
    parameter_of: syntax.Function | None = None
    parameter_index: int = -1
    #: The string this local was initialised with, while it is never reassigned.
    initial_string: str | None = None
    #: Every value expression assigned to the symbol, the initialiser included.
    assigned_values: list[syntax.Expression] = field(default_factory=list)
    #: Whether some assignment gave it a value this analysis could not see
    #: (`local a, b = f()` for `b`, a `for` variable).
    has_unknown_value: bool = False

    @property
    def constant_string(self) -> str | None:
        """The string value, when the symbol is a string constant."""
        if self.initial_string is not None and len(self.assigned_values) == 1 and not self.has_unknown_value:
            return self.initial_string
        return None

    @property
    def only_function(self) -> syntax.Function | None:
        """The function value, when the symbol is assigned exactly one function and nothing else."""
        if len(self.assigned_values) == 1 and not self.has_unknown_value:
            value = self.assigned_values[0]
            if isinstance(value, syntax.Function):
                return value
        return None

    @property
    def is_global_table_alias(self) -> bool:
        """Whether the symbol is only ever `_G` (`local GLOBALS = _G`)."""
        return (
            len(self.assigned_values) == 1
            and not self.has_unknown_value
            and isinstance(self.assigned_values[0], syntax.Name)
            and self.assigned_values[0].name == GLOBAL_TABLE
        )


class _Resolver:
    """Bind every `Name` node to its `Symbol`, or to `None` for a global."""

    def __init__(self) -> None:
        self.bindings: dict[int, Symbol | None] = {}
        self.scopes: list[dict[str, Symbol]] = []

    def resolve(self, chunk: syntax.Chunk) -> dict[int, Symbol | None]:
        self.scopes = [{}]
        self.block(chunk.body)
        return self.bindings

    def lookup(self, name: str) -> Symbol | None:
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        return None

    def declare(self, node: syntax.Name, **attributes: object) -> Symbol:
        symbol = Symbol(node.name, node.line, **attributes)  # type: ignore[arg-type]
        self.scopes[-1][node.name] = symbol
        self.bindings[id(node)] = symbol
        return symbol

    def block(self, block: syntax.Block | None, *, new_scope: bool = True) -> None:
        if block is None:
            return
        if new_scope:
            self.scopes.append({})
        for statement in block.statements:
            self.statement(statement)
        if new_scope:
            self.scopes.pop()

    def function(self, function: syntax.Function) -> None:
        self.scopes.append({})
        if function.is_method:
            self_node = syntax.Name(function.line, function.column, name="self")
            self.declare(self_node, has_unknown_value=True)
        for index, parameter in enumerate(function.parameters):
            self.declare(parameter, parameter_of=function, parameter_index=index, has_unknown_value=True)
        self.block(function.body, new_scope=False)
        self.scopes.pop()

    def assign_to(self, target: syntax.Expression, value: syntax.Expression | None) -> None:
        if isinstance(target, syntax.Name):
            self.expression(target)
            symbol = self.bindings.get(id(target))
            if symbol is not None:
                if value is None:
                    symbol.has_unknown_value = True
                else:
                    symbol.assigned_values.append(value)
        else:
            self.expression(target)

    def statement(self, statement: syntax.Statement) -> None:
        if isinstance(statement, syntax.Local):
            for value in statement.values:
                self.expression(value)
            for index, name in enumerate(statement.names):
                value = _value_at(statement.values, index)
                symbol = self.declare(name)
                if value is None:
                    # `local a, b = f()`: `b` takes a result this analysis cannot see.
                    symbol.has_unknown_value = bool(statement.values) and isinstance(
                        statement.values[-1], (syntax.Call, syntax.MethodCall, syntax.Vararg)
                    )
                else:
                    symbol.assigned_values.append(value)
                    if isinstance(value, syntax.String):
                        symbol.initial_string = value.value
            return
        if isinstance(statement, syntax.LocalFunction):
            symbol = self.declare(statement.name)
            symbol.assigned_values.append(statement.function)
            self.function(statement.function)
            return
        if isinstance(statement, syntax.FunctionDeclaration):
            self.assign_to(statement.target, statement.function)
            self.function(statement.function)
            return
        if isinstance(statement, syntax.Assign):
            for value in statement.values:
                self.expression(value)
            for index, target in enumerate(statement.targets):
                self.assign_to(target, _value_at(statement.values, index))
            return
        if isinstance(statement, syntax.NumericFor):
            for expression in (statement.start, statement.stop, statement.step):
                if expression is not None:
                    self.expression(expression)
            self.scopes.append({})
            self.declare(statement.variable, has_unknown_value=True)
            self.block(statement.body, new_scope=False)
            self.scopes.pop()
            return
        if isinstance(statement, syntax.GenericFor):
            for value in statement.values:
                self.expression(value)
            self.scopes.append({})
            for name in statement.names:
                self.declare(name, has_unknown_value=True)
            self.block(statement.body, new_scope=False)
            self.scopes.pop()
            return
        if isinstance(statement, syntax.Repeat):
            self.scopes.append({})
            self.block(statement.body, new_scope=False)
            self.expression(statement.condition)
            self.scopes.pop()
            return
        for child in syntax.children(statement):
            if isinstance(child, syntax.Block):
                self.block(child)
            elif isinstance(child, syntax.IfClause):
                self.expression(child.condition)
                self.block(child.body)
            elif isinstance(child, syntax.Expression):
                self.expression(child)

    def expression(self, expression: syntax.Node | None) -> None:
        if expression is None:
            return
        if isinstance(expression, syntax.Name):
            self.bindings[id(expression)] = self.lookup(expression.name)
            return
        if isinstance(expression, syntax.Function):
            self.function(expression)
            return
        for child in syntax.children(expression):
            self.expression(child)


def _value_at(values: list[syntax.Expression], index: int) -> syntax.Expression | None:
    """The expression assigned to position `index` of a multiple assignment, if any."""
    return values[index] if index < len(values) else None


# Values, origins and facts ----------------------------------------------------


@dataclass(frozen=True)
class Origin:
    """Where a host value came from: a reference, or a helper's template read."""

    #: `("reference", key)` in the main pass, `("template", key)` in a summary.
    kind: str
    key: tuple
    name: str


#: A group of origins any one of which being present makes the value present.
Alternatives = tuple[Origin, ...]

#: A host value is a frozenset of `Alternatives` groups, each of which must be
#: satisfied (a variable assigned two different reads can hold either one).
EMPTY: frozenset = frozenset()

#: A path a fact is about: a root (a `Symbol`, or `("global", name)`) followed
#: by field names.
PathKey = tuple


@dataclass
class TemplateRead:
    """One read a helper performs on its parameters, before substitution."""

    kind: str
    name: str
    line: int
    column: int
    returned: bool = False
    unguarded_uses: list[Use] = field(default_factory=list)
    guard_lines: list[int] = field(default_factory=list)

    def signature(self) -> tuple:
        return (
            self.kind,
            self.name,
            self.line,
            self.column,
            self.returned,
            tuple((use.line, use.reason, use.alternatives) for use in self.unguarded_uses),
        )


@dataclass
class HelperSummary:
    """What calling a reader helper does, in terms of its parameters."""

    name: str
    reads: list[TemplateRead] = field(default_factory=list)
    #: Whether some path returns a value that may be absent whatever the caller
    #: passes: `nil`, `false`, an untested host value, or the end of the body.
    may_return_absent: bool = False
    #: Parameters returned as they are: absent exactly when the argument is.
    returned_parameters: set[int] = field(default_factory=set)
    #: The groups of template reads the helper returns (`a or b` stays one
    #: group of alternatives), by template key.
    returned_groups: set[tuple] = field(default_factory=set)

    def signature(self) -> tuple:
        return (
            tuple(read.signature() for read in self.reads),
            self.may_return_absent,
            tuple(sorted(self.returned_parameters)),
            tuple(sorted(self.returned_groups)),
        )

    def returns_absent(self, arguments: list[syntax.Expression]) -> bool:
        """Whether a call with `arguments` may evaluate to an absent value."""
        if self.may_return_absent:
            return True
        for index in self.returned_parameters:
            if index >= len(arguments) or not _certainly_truthy(arguments[index]):
                return True
        return False


class _Parameter:
    """The value of a helper's parameter while its body is summarised."""

    def __init__(self, index: int) -> None:
        self.index = index


def _substitute(template: str, arguments: list[str | None]) -> str | None:
    """Replace `{i}` placeholders with argument strings, or `None` if one is unknown."""
    missing = False

    def replace(match: re.Match[str]) -> str:
        nonlocal missing
        index = int(match.group(1))
        if index >= len(arguments) or arguments[index] is None:
            missing = True
            return ""
        return str(arguments[index])

    result = _PLACEHOLDER_RE.sub(replace, template)
    return None if missing else result


def _is_template(name: str) -> bool:
    return _PLACEHOLDER_RE.search(name) is not None


# The analysis ------------------------------------------------------------------


class FileAnalysis:
    """Extract the host references of one parsed file.

    `widget_methods` and `event_names` are the script-object methods and event
    names the captured documentation knows on any flavour; they decide which
    method calls and string literals are host references at all.
    """

    def __init__(
        self,
        chunk: syntax.Chunk,
        file: str,
        widget_methods: frozenset[str],
        event_names: frozenset[str],
    ) -> None:
        self.chunk = chunk
        self.file = file
        self.widget_methods = widget_methods
        self.event_names = event_names
        self.bindings = _Resolver().resolve(chunk)
        self.helpers: dict[int, HelperSummary] = {}
        #: `id()` of every helper's function node, for `_is_helper_parameter`.
        self.helper_functions: set[int] = set()
        self.references: dict[tuple, Reference] = {}
        self.symbol_values: dict[int, set[Alternatives]] = {}
        # Per-run state.
        self.summarising: syntax.Function | None = None
        self.summary: HelperSummary | None = None
        self.templates: dict[tuple, TemplateRead] = {}
        #: Whether origins become references (main pass) or scratch (summary).
        self.record = False
        #: The reference keys the latest main pass reached.
        self.references_seen: set[tuple] = set()

    # Public entry point

    def run(self) -> list[Reference]:
        """Summarise the helpers, then analyse the file; return its references."""
        self._summarise_helpers()
        self.helper_functions = {
            id(symbol.only_function)
            for symbol in self.bindings.values()
            if symbol is not None and id(symbol) in self.helpers
        }
        previous = None
        for _ in range(_MAX_ROUNDS):
            self.references_seen = set()
            for reference in self.references.values():
                reference.unguarded_uses.clear()
                reference.guard_lines.clear()
            self.record = True
            self.summarising = None
            self._walk_block(self.chunk.body, frozenset())
            self._collect_events()
            self._report_escaped_helpers()
            state = self._binding_state()
            if state == previous:
                break
            previous = state
        live = [self.references[key] for key in self.references if key in self.references_seen]
        return sorted(live, key=lambda reference: (reference.line, reference.column, reference.name))

    def _report_escaped_helpers(self) -> None:
        """Report the reads of helpers whose call sites this analysis cannot see.

        A helper stored in a table or passed along is called with names only
        known at run time, so each of its reads becomes a dynamic reference at
        the read itself, carrying the helper's own unprotected uses and, when
        it can hand back an absent value, the return.
        """
        not_escaping: set[int] = set()
        for node in syntax.walk(self.chunk):
            if isinstance(node, syntax.Call) and isinstance(node.function, syntax.Name):
                not_escaping.add(id(node.function))
            elif isinstance(node, syntax.LocalFunction) and node.name is not None:
                not_escaping.add(id(node.name))
            elif isinstance(node, syntax.FunctionDeclaration):
                not_escaping.add(id(node.target))
            elif isinstance(node, syntax.Local):
                not_escaping.update(id(name) for name in node.names)
            elif isinstance(node, syntax.Assign):
                not_escaping.update(id(target) for target in node.targets)
        escaped: set[int] = set()
        for node in syntax.walk(self.chunk):
            if isinstance(node, syntax.Name) and id(node) not in not_escaping:
                symbol = self.bindings.get(id(node))
                if symbol is not None and id(symbol) in self.helpers:
                    escaped.add(id(symbol))
        for symbol_id in escaped:
            helper = self.helpers[symbol_id]
            for read in helper.reads:
                if _is_field_of_parameter_global(read.name):
                    # A field of a global the caller names is data (see _member_origin).
                    continue
                name = f"{helper.name}(…)"
                node = syntax.Name(read.line, read.column, name=name)
                origin = self._origin(KIND_DYNAMIC, name, node, helper.name)
                if origin is None:
                    continue
                for use in read.unguarded_uses:
                    self._record_use(origin, Use(use.line, use.reason, (name,)))
                if read.returned and (helper.may_return_absent or helper.returned_parameters):
                    reason = f"returned by {helper.name}, which is called where this check cannot see"
                    self._record_use(origin, Use(read.line, reason, (name,)))

    def _binding_state(self) -> tuple:
        return tuple(sorted((key, len(groups)) for key, groups in self.symbol_values.items()))

    # Helpers

    def _helper_candidates(self) -> list[tuple[Symbol, syntax.Function]]:
        seen: dict[int, tuple[Symbol, syntax.Function]] = {}
        for symbol in self.bindings.values():
            if symbol is None or id(symbol) in seen:
                continue
            function = symbol.only_function
            if function is not None and function.parameters:
                seen[id(symbol)] = (symbol, function)
        return sorted(seen.values(), key=lambda pair: pair[0].line)

    def _summarise_helpers(self) -> None:
        candidates = self._helper_candidates()
        for _ in range(_MAX_ROUNDS):
            changed = False
            for symbol, function in candidates:
                summary = self._summarise(symbol, function)
                current = self.helpers.get(id(symbol))
                if summary.reads:
                    if current is None or current.signature() != summary.signature():
                        self.helpers[id(symbol)] = summary
                        changed = True
                elif current is not None:
                    del self.helpers[id(symbol)]
                    changed = True
            if not changed:
                return

    def _summarise(self, symbol: Symbol, function: syntax.Function) -> HelperSummary:
        self.record = False
        self.summarising = function
        self.summary = HelperSummary(symbol.name)
        self.templates = {}
        saved_values = self.symbol_values
        self.symbol_values = {}
        for _ in range(_MAX_ROUNDS):
            before = self._binding_state()
            for template in self.templates.values():
                template.unguarded_uses.clear()
                template.guard_lines.clear()
                template.returned = False
            self.summary.may_return_absent = False
            self.summary.returned_parameters = set()
            self.summary.returned_groups = set()
            _, exits = self._walk_block(function.body, frozenset())
            if not exits:
                # Falling off the end of the body returns nothing.
                self.summary.may_return_absent = True
            if self._binding_state() == before:
                break
        self.summary.reads = sorted(
            self.templates.values(), key=lambda read: (read.line, read.column, read.name)
        )
        summary = self.summary
        self.symbol_values = saved_values
        self.summarising = None
        self.summary = None
        return summary

    # Origins

    def _origin(self, kind: str, name: str, node: syntax.Node, via: str | None = None) -> Origin | None:
        """Create (or find) the origin for reading `name` at `node`."""
        if _is_template(name):
            if self.summarising is None:
                return None
            key = (kind, name, node.line, node.column)
            if key not in self.templates:
                self.templates[key] = TemplateRead(kind, name, node.line, node.column)
            return Origin("template", key, name)
        if not self.record:
            # Concrete reads inside a helper body are recorded by the main pass;
            # the summary still tracks them so their fields become templates.
            return Origin("scratch", (kind, name, node.line, node.column), name)
        key = (kind, name, node.line, node.column, via)
        reference = self.references.get(key)
        if reference is None:
            reference = Reference(self.file, node.line, node.column, kind, name, via=via)
            self.references[key] = reference
        self.references_seen.add(key)
        return Origin("reference", key, name)

    def _mark(self, value: frozenset, line: int, reason: str) -> None:
        """Record an unprotected use of every origin in `value`."""
        for group in value:
            alternatives = tuple(origin.name for origin in group)
            for origin in group:
                use = Use(line, reason, alternatives)
                if origin.kind == "reference":
                    self.references[origin.key].unguarded_uses.append(use)
                elif origin.kind == "template":
                    self.templates[origin.key].unguarded_uses.append(use)

    def _note_guard(self, value: frozenset, line: int) -> None:
        for group in value:
            for origin in group:
                if origin.kind == "reference":
                    lines = self.references[origin.key].guard_lines
                elif origin.kind == "template":
                    lines = self.templates[origin.key].guard_lines
                else:
                    continue
                if line not in lines:
                    lines.append(line)

    def _mark_returned(self, value: frozenset) -> None:
        for group in value:
            keys = tuple(origin.key for origin in group if origin.kind == "template")
            for key in keys:
                self.templates[key].returned = True
            if keys and self.summary is not None:
                self.summary.returned_groups.add(keys)

    # Walking statements

    def _walk_block(self, block: syntax.Block | None, facts: frozenset) -> tuple[frozenset, bool]:
        if block is None:
            return facts, False
        for statement in block.statements:
            facts, exits = self._walk_statement(statement, facts)
            if exits:
                return facts, True
        return facts, False

    def _walk_statement(self, statement: syntax.Statement, facts: frozenset) -> tuple[frozenset, bool]:
        if isinstance(statement, syntax.Local):
            values = [self._evaluate(value, facts) for value in statement.values]
            for index, name in enumerate(statement.names):
                symbol = self.bindings.get(id(name))
                if index < len(values) and symbol is not None:
                    self._bind(symbol, values[index], statement.values[index], facts)
            return facts, False
        if isinstance(statement, syntax.LocalFunction):
            self._walk_nested_function(statement.function)
            return facts, False
        if isinstance(statement, syntax.FunctionDeclaration):
            if not isinstance(statement.target, syntax.Name):
                self._evaluate_target(statement.target, facts)
            self._walk_nested_function(statement.function)
            return self._kill(facts, statement.target), False
        if isinstance(statement, syntax.Assign):
            return self._walk_assign(statement, facts), False
        if isinstance(statement, syntax.CallStatement):
            self._evaluate(statement.call, facts)
            return facts, self._is_error_call(statement.call)
        if isinstance(statement, syntax.Do):
            return self._walk_block(statement.body, facts)
        if isinstance(statement, syntax.If):
            return self._walk_if(statement, facts)
        if isinstance(statement, syntax.While):
            loop_facts = self._loop_entry(facts, statement.body)
            self._evaluate(statement.condition, loop_facts, condition=True)
            positive, _ = self._facts_of(statement.condition)
            self._walk_block(statement.body, loop_facts | positive)
            return loop_facts, False
        if isinstance(statement, syntax.Repeat):
            loop_facts = self._loop_entry(facts, statement.body)
            end_facts, _ = self._walk_block(statement.body, loop_facts)
            self._evaluate(statement.condition, end_facts, condition=True)
            return loop_facts, False
        if isinstance(statement, syntax.NumericFor):
            for expression in (statement.start, statement.stop, statement.step):
                if expression is not None:
                    self._use(expression, self._evaluate(expression, facts), facts, "used in a loop bound")
            loop_facts = self._loop_entry(facts, statement.body)
            self._walk_block(statement.body, loop_facts)
            return loop_facts, False
        if isinstance(statement, syntax.GenericFor):
            for expression in statement.values:
                self._use(expression, self._evaluate(expression, facts), facts, "iterated")
            loop_facts = self._loop_entry(facts, statement.body)
            self._walk_block(statement.body, loop_facts)
            return loop_facts, False
        if isinstance(statement, syntax.Return):
            for position, expression in enumerate(statement.values):
                value = self._evaluate(expression, facts)
                if self.summarising is not None:
                    self._mark_returned(value)
                    self._escape_unless_template(expression, value, facts)
                    if position == 0:
                        self._classify_return(expression, value, facts)
                else:
                    self._use(expression, value, facts, "returned to a caller")
            if not statement.values and self.summary is not None:
                self.summary.may_return_absent = True
            return facts, True
        if isinstance(statement, syntax.Break):
            return facts, True
        return facts, False

    def _classify_return(self, expression: syntax.Expression, value: frozenset, facts: frozenset) -> None:
        """Record whether this return of the summarised helper can hand back an absent value."""
        assert self.summary is not None
        if _certainly_truthy(expression):
            return
        if value and self._known_present(expression, facts):
            return
        parameter = self._string_parameter(expression)
        if parameter is not None and not value:
            self.summary.returned_parameters.add(parameter)
            return
        self.summary.may_return_absent = True

    def _string_parameter(self, expression: syntax.Expression) -> int | None:
        """The index of the summarised helper's parameter `expression` names, if it does."""
        if isinstance(expression, syntax.Name):
            symbol = self.bindings.get(id(expression))
            if (
                symbol is not None
                and symbol.parameter_of is self.summarising
                and not symbol.assigned_values
            ):
                return symbol.parameter_index
        return None

    def _walk_nested_function(self, function: syntax.Function) -> None:
        # A closure can run at any later time: no fact of the enclosing code holds.
        self._walk_block(function.body, frozenset())

    def _walk_assign(self, statement: syntax.Assign, facts: frozenset) -> frozenset:
        values = [self._evaluate(value, facts) for value in statement.values]
        for target in statement.targets:
            if not isinstance(target, syntax.Name):
                self._evaluate_target(target, facts)
        for index, target in enumerate(statement.targets):
            value = values[index] if index < len(values) else EMPTY
            expression = statement.values[index] if index < len(statement.values) else None
            symbol = self.bindings.get(id(target)) if isinstance(target, syntax.Name) else None
            if symbol is not None:
                self._bind(symbol, value, expression, facts)
            elif expression is not None:
                self._use(expression, value, facts, "stored where this check cannot follow it")
            facts = self._kill(facts, target)
            if symbol is not None and expression is not None and _certainly_truthy(expression):
                facts = facts | {(symbol,)}
        return facts

    def _walk_if(self, statement: syntax.If, facts: frozenset) -> tuple[frozenset, bool]:
        outcomes: list[frozenset] = []
        current = facts
        for clause in statement.clauses:
            self._evaluate(clause.condition, current, condition=True)
            positive, negative = self._facts_of(clause.condition)
            branch_facts, exits = self._walk_block(clause.body, current | positive)
            if not exits:
                outcomes.append(branch_facts)
            current = current | negative
        if statement.orelse is not None:
            branch_facts, exits = self._walk_block(statement.orelse, current)
            if not exits:
                outcomes.append(branch_facts)
        else:
            outcomes.append(current)
        if not outcomes:
            return facts, True
        merged = outcomes[0]
        for outcome in outcomes[1:]:
            merged = merged & outcome
        return merged, False

    def _loop_entry(self, facts: frozenset, body: syntax.Block | None) -> frozenset:
        """Facts that survive any number of loop iterations."""
        if body is None:
            return facts
        for node in syntax.walk(body):
            if isinstance(node, syntax.Assign):
                for target in node.targets:
                    facts = self._kill(facts, target)
            elif isinstance(node, syntax.FunctionDeclaration):
                facts = self._kill(facts, node.target)
        return facts

    def _kill(self, facts: frozenset, target: syntax.Expression) -> frozenset:
        """Drop every fact about `target` and the fields below it."""
        path = self._path(target)
        if path is None:
            return facts
        return frozenset(fact for fact in facts if fact[: len(path)] != path)

    def _bind(
        self,
        symbol: Symbol,
        value: frozenset,
        expression: syntax.Expression | None,
        facts: frozenset,
    ) -> None:
        """Let `symbol` carry the host value `value` from here on.

        A value already proved present where it is assigned (`count =
        hostCount` inside `if type(hostCount) == "number"`) is not carried:
        the variable then never holds an absent host value, whatever else the
        code stores in it.
        """
        if not value or expression is None:
            return
        if self._known_present(expression, facts):
            self._note_guard(value, expression.line)
            return
        groups = self.symbol_values.setdefault(id(symbol), set())
        groups.update(value)

    def _is_error_call(self, call: syntax.Expression) -> bool:
        """Whether a call statement is `error(...)`, which never returns."""
        return isinstance(call, syntax.Call) and self._is_builtin(call.function, "error")

    # Paths and facts

    def _path(self, expression: syntax.Expression | None) -> PathKey | None:
        """The path an expression denotes, if it denotes a stable storage location."""
        if isinstance(expression, syntax.Parenthesized):
            return self._path(expression.expression)
        if isinstance(expression, syntax.Name):
            symbol = self.bindings.get(id(expression))
            if symbol is None:
                return (("global", expression.name),)
            return (symbol,)
        if isinstance(expression, syntax.Index):
            base = self._path(expression.target)
            key = self._string(expression.key)
            if base is None or not isinstance(key, str):
                return None
            return base + (key,)
        if isinstance(expression, syntax.Call) and self._is_builtin(expression.function, "rawget"):
            if len(expression.arguments) >= 2:
                base = self._path(expression.arguments[0])
                key = self._string(expression.arguments[1])
                if base is not None and isinstance(key, str):
                    return base + (key,)
        return None

    def _facts_of(self, condition: syntax.Expression | None) -> tuple[frozenset, frozenset]:
        """The paths proved present when `condition` is true, and when it is false."""
        if condition is None:
            return EMPTY, EMPTY
        if isinstance(condition, syntax.Parenthesized):
            return self._facts_of(condition.expression)
        if isinstance(condition, syntax.UnaryOperation) and condition.operator == "not":
            positive, negative = self._facts_of(condition.operand)
            return negative, positive
        if isinstance(condition, syntax.BinaryOperation):
            if condition.operator == "and":
                left_positive, left_negative = self._facts_of(condition.left)
                right_positive, right_negative = self._facts_of(condition.right)
                return left_positive | right_positive, left_negative & right_negative
            if condition.operator == "or":
                left_positive, left_negative = self._facts_of(condition.left)
                right_positive, right_negative = self._facts_of(condition.right)
                return left_positive & right_positive, left_negative | right_negative
            if condition.operator in ("==", "~="):
                return self._comparison_facts(condition)
            return EMPTY, EMPTY
        path = self._path(condition)
        if path is not None:
            return self._with_implied(frozenset({path})), EMPTY
        return EMPTY, EMPTY

    def _with_implied(self, facts: frozenset, depth: int = 0) -> frozenset:
        """Add what a present local implies, when it holds a stored test.

        `local setup = type(picker) == "table" and picker.Setup or nil`: when
        `setup` is present, so are `picker` and `picker.Setup`. Only a local
        assigned once is expanded, and only facts about paths whose root is
        assigned at most once, so no later assignment can make them stale.
        """
        if depth > 4:
            return facts
        implied = set(facts)
        for fact in facts:
            if len(fact) != 1 or not isinstance(fact[0], Symbol):
                continue
            symbol = fact[0]
            if len(symbol.assigned_values) != 1 or symbol.has_unknown_value:
                continue
            for extra in self._truthy_facts(symbol.assigned_values[0]):
                if self._stable_root(extra[0]):
                    implied.add(extra)
        result = frozenset(implied)
        if result != facts:
            return self._with_implied(result, depth + 1)
        return result

    def _truthy_facts(self, expression: syntax.Expression | None) -> frozenset:
        """Paths proved present whenever `expression` evaluates to a true value."""
        if isinstance(expression, syntax.Parenthesized):
            return self._truthy_facts(expression.expression)
        if isinstance(expression, syntax.BinaryOperation):
            if expression.operator == "and":
                positive, _ = self._facts_of(expression.left)
                return positive | self._truthy_facts(expression.right)
            if expression.operator == "or":
                if isinstance(expression.right, (syntax.Nil, syntax.Boolean)) and not _certainly_truthy(
                    expression.right
                ):
                    return self._truthy_facts(expression.left)
                return self._truthy_facts(expression.left) & self._truthy_facts(expression.right)
            if expression.operator in ("==", "~="):
                positive, _ = self._comparison_facts(expression)
                return positive
            return EMPTY
        if isinstance(expression, syntax.UnaryOperation) and expression.operator == "not":
            _, negative = self._facts_of(expression.operand)
            return negative
        path = self._path(expression)
        if path is not None:
            return frozenset({path})
        return EMPTY

    def _stable_root(self, root: object) -> bool:
        """Whether a fact about paths under `root` cannot be invalidated by reassignment."""
        if not isinstance(root, Symbol):
            return True
        if root.parameter_of is not None:
            return not root.assigned_values
        return len(root.assigned_values) <= 1 and not root.has_unknown_value

    def _comparison_facts(self, condition: syntax.BinaryOperation) -> tuple[frozenset, frozenset]:
        for tested, other in ((condition.left, condition.right), (condition.right, condition.left)):
            # type(path) == "function" (any type name but "nil")
            if isinstance(tested, syntax.Call) and self._is_builtin(tested.function, "type"):
                if len(tested.arguments) == 1 and isinstance(other, syntax.String):
                    path = self._path(tested.arguments[0])
                    if path is None:
                        continue
                    present_when_equal = other.value != "nil"
                    proved = self._with_implied(frozenset({path}))
                    if condition.operator == "==":
                        return (proved, EMPTY) if present_when_equal else (EMPTY, proved)
                    return (EMPTY, proved) if present_when_equal else (proved, EMPTY)
            # path ~= nil
            if isinstance(other, syntax.Nil):
                path = self._path(tested)
                if path is None:
                    continue
                proved = self._with_implied(frozenset({path}))
                return (proved, EMPTY) if condition.operator == "~=" else (EMPTY, proved)
        return EMPTY, EMPTY

    def _known_present(self, expression: syntax.Expression, facts: frozenset) -> bool:
        path = self._path(expression)
        if path is None:
            return False
        return any(fact[: len(path)] == path for fact in facts)

    # Uses

    def _use(self, expression: syntax.Expression, value: frozenset, facts: frozenset, reason: str) -> None:
        """`value` (of `expression`) is used in a way that fails when it is absent."""
        if not value:
            return
        if self._known_present(expression, facts):
            self._note_guard(value, expression.line)
            return
        self._mark(value, expression.line, reason)

    def _escape_unless_template(
        self, expression: syntax.Expression, value: frozenset, facts: frozenset
    ) -> None:
        """A helper returning a value hands it to the call site; anything else escapes."""
        if self._known_present(expression, facts):
            self._note_guard(value, expression.line)
        non_template = frozenset(
            group for group in value if not any(origin.kind == "template" for origin in group)
        )
        self._use(expression, non_template, facts, "returned to a caller")

    def _probe(self, value: frozenset, line: int) -> None:
        """`value` only appears in a test: the read handles absence by itself."""
        self._note_guard(value, line)

    # Expressions

    def _string(self, expression: syntax.Expression | None) -> str | _Parameter | None:
        """The string an expression certainly evaluates to, a helper parameter, or `None`."""
        if isinstance(expression, syntax.String):
            return expression.value
        if isinstance(expression, syntax.Parenthesized):
            return self._string(expression.expression)
        if isinstance(expression, syntax.Name):
            symbol = self.bindings.get(id(expression))
            if symbol is None:
                return None
            if symbol.parameter_of is not None and symbol.parameter_of is self.summarising:
                if not symbol.assigned_values:
                    return _Parameter(symbol.parameter_index)
            return symbol.constant_string
        return None

    def _name_text(self, expression: syntax.Expression | None) -> str | None:
        """A name usable in an origin: a literal, `{i}` in a summary, else `None`."""
        value = self._string(expression)
        if isinstance(value, _Parameter):
            return "{" + str(value.index) + "}"
        return value

    def _is_builtin(self, expression: syntax.Expression | None, name: str) -> bool:
        """Whether `expression` is the built-in `name`, directly or through a local alias.

        `local type = type` at the top of a file is a common Lua idiom; the
        alias is the built-in as long as it is never reassigned.
        """
        if not isinstance(expression, syntax.Name):
            return False
        symbol = self.bindings.get(id(expression))
        if symbol is None:
            return expression.name == name
        if len(symbol.assigned_values) != 1 or symbol.has_unknown_value:
            return False
        value = symbol.assigned_values[0]
        return (
            isinstance(value, syntax.Name)
            and value.name == name
            and self.bindings.get(id(value)) is None
        )

    def _is_global_table(self, expression: syntax.Expression | None) -> bool:
        if isinstance(expression, syntax.Parenthesized):
            return self._is_global_table(expression.expression)
        if not isinstance(expression, syntax.Name):
            return False
        symbol = self.bindings.get(id(expression))
        if symbol is None:
            return expression.name == GLOBAL_TABLE
        return symbol.is_global_table_alias

    def _summarised_parameter_in(self, expression: syntax.Expression | None) -> int | None:
        """The first parameter of the helper being summarised that `expression` mentions."""
        if expression is None or self.summarising is None:
            return None
        for node in syntax.walk(expression):
            if isinstance(node, syntax.Name):
                symbol = self.bindings.get(id(node))
                if symbol is not None and symbol.parameter_of is self.summarising:
                    return symbol.parameter_index
        return None

    def _is_helper_parameter(self, expression: syntax.Expression | None) -> bool:
        """Whether `expression` mentions a reader helper's parameter (main pass only).

        Such a read is represented at each call site of the helper instead.
        """
        if expression is None:
            return False
        for node in syntax.walk(expression):
            if isinstance(node, syntax.Name):
                symbol = self.bindings.get(id(node))
                if symbol is not None and id(symbol.parameter_of) in self.helper_functions:
                    return True
        return False

    def _global_read(
        self, key: syntax.Expression | None, node: syntax.Node, via: str | None = None
    ) -> frozenset:
        """A read of the global named by `key`, as a value."""
        name = self._name_text(key)
        if name is None:
            if self.summarising is None and self._is_helper_parameter(key):
                return EMPTY
            parameter = self._summarised_parameter_in(key)
            if parameter is not None:
                # A name computed from a parameter (`name:sub(1, dot - 1)`): a
                # run-time name at every call site, whose uses are judged there.
                origin = self._origin(KIND_DYNAMIC, "name computed from {" + str(parameter) + "}", node, via)
                return frozenset({(origin,)}) if origin is not None else EMPTY
            origin = self._origin(KIND_DYNAMIC, _describe_dynamic(key), node, via)
        else:
            origin = self._origin(KIND_GLOBAL, name, node, via)
        return frozenset({(origin,)}) if origin is not None else EMPTY

    def _member_read(self, base: frozenset, key: syntax.Expression | None, node: syntax.Node) -> frozenset:
        """A read of field `key` of a host value, as a value of member origins."""
        key_name = self._name_text(key)
        if key_name is None and self.summarising is None and self._is_helper_parameter(key):
            return EMPTY
        groups = set()
        for group in base:
            members = []
            for origin in group:
                member = self._member_origin(origin, key_name, key, node)
                if member is not None:
                    members.append(member)
            if members:
                groups.add(tuple(members))
        return frozenset(groups)

    def _member_origin(
        self, base: Origin, key_name: str | None, key: syntax.Expression | None, node: syntax.Node
    ) -> Origin | None:
        """The origin of field `key` of the host value `base`, or `None`.

        A global read by a name computed at run time (an addon's saved
        variables, a `SLASH_` string) is data, and its fields are data whose
        shape the Kit validates; the gate judges whether the read itself
        handles absence, and does not follow the fields.
        """
        if base.key[0] == KIND_DYNAMIC:
            return None
        if key_name is None:
            return self._origin(KIND_DYNAMIC, f"{base.name}[{_describe_dynamic(key)}]", node)
        return self._origin(KIND_MEMBER, f"{base.name}.{key_name}", node)

    def _method_read(self, method: str, node: syntax.Node) -> frozenset:
        origin = self._origin(KIND_METHOD, method, node)
        return frozenset({(origin,)}) if origin is not None else EMPTY

    def _evaluate_target(self, target: syntax.Expression, facts: frozenset) -> None:
        """Evaluate the parts of an assignment target that are read."""
        if isinstance(target, syntax.Index):
            base = self._evaluate(target.target, facts)
            self._use(target.target, base, facts, "indexed")
            self._evaluate(target.key, facts)

    def _evaluate(
        self, expression: syntax.Expression | None, facts: frozenset, condition: bool = False
    ) -> frozenset:
        """Evaluate `expression` under `facts`; return the host value it carries.

        With `condition` set the expression is a truthiness test (an `if`
        condition): a bare host value there is a probe, not a use.
        """
        if expression is None:
            return EMPTY
        if isinstance(expression, syntax.Parenthesized):
            return self._evaluate(expression.expression, facts, condition)
        if isinstance(expression, syntax.Name):
            return self._evaluate_name(expression, condition)
        if isinstance(expression, syntax.Index):
            return self._evaluate_index(expression, facts, condition)
        if isinstance(expression, syntax.Call):
            return self._evaluate_call(expression, facts, condition)
        if isinstance(expression, syntax.MethodCall):
            return self._evaluate_method_call(expression, facts)
        if isinstance(expression, syntax.Function):
            self._walk_nested_function(expression)
            return EMPTY
        if isinstance(expression, syntax.Table):
            for table_field in expression.fields:
                if table_field.key is not None:
                    self._use(table_field.key, self._evaluate(table_field.key, facts), facts, "used as a key")
                value = self._evaluate(table_field.value, facts)
                self._use(table_field.value, value, facts, "stored in a table")
            return EMPTY
        if isinstance(expression, syntax.BinaryOperation):
            return self._evaluate_binary(expression, facts, condition)
        if isinstance(expression, syntax.UnaryOperation):
            if expression.operator == "not":
                self._probe(self._evaluate(expression.operand, facts, condition=True), expression.line)
                return EMPTY
            operand = self._evaluate(expression.operand, facts)
            self._use(expression.operand, operand, facts, f"operand of '{expression.operator}'")
            return EMPTY
        return EMPTY

    def _evaluate_name(self, expression: syntax.Name, condition: bool) -> frozenset:
        symbol = self.bindings.get(id(expression))
        if symbol is None:
            if expression.name == GLOBAL_TABLE:
                return EMPTY
            origin = self._origin(KIND_GLOBAL, expression.name, expression)
            value = frozenset({(origin,)}) if origin is not None else EMPTY
        else:
            value = frozenset(self.symbol_values.get(id(symbol), ()))
        if condition:
            self._probe(value, expression.line)
        return value

    def _evaluate_index(self, expression: syntax.Index, facts: frozenset, condition: bool) -> frozenset:
        if self._is_global_table(expression.target):
            return self._global_read(expression.key, expression)
        if isinstance(expression.target, syntax.Name) and self.bindings.get(id(expression.target)) is None:
            # A field of a free name (`string.format`): one member reference.
            name = self._name_text(expression.key)
            if name is not None:
                origin = self._origin(KIND_MEMBER, f"{expression.target.name}.{name}", expression)
                value = frozenset({(origin,)}) if origin is not None else EMPTY
                if condition:
                    self._probe(value, expression.line)
                return value
        base = self._evaluate(expression.target, facts)
        self._use(expression.target, base, facts, "indexed")
        key_value = self._evaluate(expression.key, facts)
        self._use(expression.key, key_value, facts, "used as a key")
        if base:
            value = self._member_read(base, expression.key, expression)
        else:
            key_name = self._string(expression.key)
            if isinstance(key_name, str) and key_name in self.widget_methods:
                value = self._method_read(key_name, expression)
            else:
                value = EMPTY
        if condition:
            self._probe(value, expression.line)
        return value

    def _evaluate_call(self, expression: syntax.Call, facts: frozenset, condition: bool) -> frozenset:
        function = expression.function
        arguments = expression.arguments
        if self._is_builtin(function, "rawget") and len(arguments) >= 2:
            if self._is_global_table(arguments[0]):
                self._evaluate(arguments[1], facts)
                value = self._global_read(arguments[1], expression)
            else:
                base = self._evaluate(arguments[0], facts)
                self._use(arguments[0], base, facts, "indexed")
                self._evaluate(arguments[1], facts)
                value = self._member_read(base, arguments[1], expression) if base else EMPTY
                if not base:
                    key_name = self._string(arguments[1])
                    if isinstance(key_name, str) and key_name in self.widget_methods:
                        value = self._method_read(key_name, expression)
            if condition:
                self._probe(value, expression.line)
            return value
        if self._is_builtin(function, "type") and len(arguments) == 1:
            self._probe(self._evaluate(arguments[0], facts, condition=True), expression.line)
            return EMPTY
        helper = self._helper_of(function)
        if helper is not None:
            return self._evaluate_helper_call(helper, expression, facts, condition)
        callee = self._evaluate(function, facts)
        self._use(function, callee, facts, "called")
        protected_first = any(self._is_builtin(function, name) for name in PROTECTED_CALLERS)
        inspecting = any(self._is_builtin(function, name) for name in INSPECTING_BUILTINS)
        for index, argument in enumerate(arguments):
            value = self._evaluate(argument, facts)
            if (index == 0 and protected_first) or inspecting:
                self._probe(value, argument.line)
            else:
                self._use(argument, value, facts, "passed to a function")
        return EMPTY

    def _helper_of(self, function: syntax.Expression | None) -> HelperSummary | None:
        if not isinstance(function, syntax.Name):
            return None
        symbol = self.bindings.get(id(function))
        if symbol is None:
            return None
        return self.helpers.get(id(symbol))

    def _evaluate_helper_call(
        self, helper: HelperSummary, expression: syntax.Call, facts: frozenset, condition: bool
    ) -> frozenset:
        """Instantiate a helper's template reads at this call site."""
        argument_names = [self._name_text(argument) for argument in expression.arguments]
        for argument in expression.arguments:
            self._use(argument, self._evaluate(argument, facts), facts, "passed to a function")
        returned_origins: dict[tuple, Origin] = {}
        for read in helper.reads:
            name = _substitute(read.name, argument_names)
            if name is None:
                if self.summarising is None and any(
                    self._is_helper_parameter(argument) for argument in expression.arguments
                ):
                    continue
                computed_from = [self._summarised_parameter_in(argument) for argument in expression.arguments]
                parameter = next((index for index in computed_from if index is not None), None)
                if parameter is not None:
                    origin = self._origin(
                        KIND_DYNAMIC, "name computed from {" + str(parameter) + "}", expression, helper.name
                    )
                    if origin is not None:
                        self._carry_helper_read(
                            helper, read, origin, argument_names, expression, returned_origins
                        )
                    continue
                shown = ", ".join(_describe_dynamic(argument) for argument in expression.arguments)
                origin = self._origin(KIND_DYNAMIC, f"{helper.name}({shown})", expression, helper.name)
            else:
                kind = KIND_DYNAMIC if "[" in name else read.kind
                origin = self._origin(kind, name, expression, helper.name)
            if origin is None:
                continue
            self._carry_helper_read(helper, read, origin, argument_names, expression, returned_origins)
        returned: set[Alternatives] = set()
        for keys in helper.returned_groups:
            group = tuple(returned_origins[key] for key in keys if key in returned_origins)
            if group:
                returned.add(group)
        value = frozenset(returned)
        if condition:
            self._probe(value, expression.line)
        return value

    def _carry_helper_read(
        self,
        helper: HelperSummary,
        read: TemplateRead,
        origin: Origin,
        argument_names: list[str | None],
        expression: syntax.Call,
        returned_origins: dict[tuple, Origin],
    ) -> None:
        """Give the call-site origin of one template read what the helper does with it."""
        for use in read.unguarded_uses:
            alternatives = tuple(
                _substitute(alternative, argument_names) or origin.name for alternative in use.alternatives
            )
            self._record_use(origin, Use(use.line, f"{use.reason} inside {helper.name}", alternatives))
        if read.returned and helper.returns_absent(expression.arguments):
            returned_origins[(read.kind, read.name, read.line, read.column)] = origin
        else:
            self._probe(frozenset({(origin,)}), expression.line)

    def _record_use(self, origin: Origin, use: Use) -> None:
        if origin.kind == "reference":
            self.references[origin.key].unguarded_uses.append(use)
        elif origin.kind == "template":
            self.templates[origin.key].unguarded_uses.append(use)

    def _evaluate_method_call(self, expression: syntax.MethodCall, facts: frozenset) -> frozenset:
        receiver = self._evaluate(expression.receiver, facts)
        self._use(expression.receiver, receiver, facts, "indexed")
        method_node = syntax.Name(expression.method_line, expression.method_column, name=expression.method)
        if receiver and expression.method in STRING_METHODS:
            # `value:upper()` on a value just proved present: a string method.
            pass
        elif receiver:
            member = self._member_read(receiver, syntax.String(0, 0, value=expression.method), method_node)
            self._use_method(expression, member, facts)
        elif expression.method in self.widget_methods:
            self._use_method(expression, self._method_read(expression.method, method_node), facts)
        if expression.method in EVENT_REGISTRATION_METHODS and expression.arguments:
            self._event_argument(expression.arguments[0])
        for argument in expression.arguments:
            self._use(argument, self._evaluate(argument, facts), facts, "passed to a function")
        return EMPTY

    def _use_method(self, expression: syntax.MethodCall, value: frozenset, facts: frozenset) -> None:
        path = self._path(expression.receiver)
        if path is not None and any(fact[: len(path) + 1] == path + (expression.method,) for fact in facts):
            self._note_guard(value, expression.method_line)
            return
        self._mark(value, expression.method_line, "called")

    def _evaluate_binary(
        self, expression: syntax.BinaryOperation, facts: frozenset, condition: bool
    ) -> frozenset:
        operator = expression.operator
        if operator == "and":
            left = self._evaluate(expression.left, facts, condition=True)
            self._probe(left, expression.left.line)
            positive, _ = self._facts_of(expression.left)
            return self._evaluate(expression.right, facts | positive, condition)
        if operator == "or":
            left = self._evaluate(expression.left, facts, condition=True)
            _, negative = self._facts_of(expression.left)
            right = self._evaluate(expression.right, facts | negative, condition)
            if condition:
                self._probe(left, expression.left.line)
                return right
            if _certainly_truthy(expression.right):
                self._probe(left, expression.left.line)
                return right
            if not left:
                return right
            if not right:
                return left
            return frozenset(a + b for a in left for b in right)
        if operator in ("==", "~="):
            self._probe(self._evaluate(expression.left, facts, condition=True), expression.line)
            self._probe(self._evaluate(expression.right, facts, condition=True), expression.line)
            return EMPTY
        for operand in (expression.left, expression.right):
            value = self._evaluate(operand, facts)
            self._use(operand, value, facts, f"operand of '{operator}'")
        return EMPTY

    # Events

    def _event_argument(self, argument: syntax.Expression) -> None:
        value = self._string(argument)
        if isinstance(value, str) and EVENT_NAME_RE.match(value) and value not in self.event_names:
            self._event_reference(value, argument)

    def _event_reference(self, name: str, node: syntax.Node) -> None:
        origin = self._origin(KIND_EVENT, name, node)
        if origin is not None and origin.kind == "reference":
            reference = self.references[origin.key]
            reference.unguarded_uses.append(Use(node.line, "registered by name", (name,)))

    def _collect_events(self) -> None:
        for node in syntax.walk(self.chunk):
            if isinstance(node, syntax.String) and node.line > 0 and node.value in self.event_names:
                self._event_reference(node.value, node)


def _is_field_of_parameter_global(template: str) -> bool:
    """Whether a template names a field below a global named by a parameter: `{1}.profileKeys`."""
    return template.startswith("{") and _PLACEHOLDER_RE.fullmatch(template) is None and (
        "." in template or "[" in template
    )


def _certainly_truthy(expression: syntax.Expression | None) -> bool:
    """Whether the expression can never be `nil` or `false`."""
    if isinstance(expression, syntax.Parenthesized):
        return _certainly_truthy(expression.expression)
    if isinstance(expression, syntax.Boolean):
        return expression.value
    return isinstance(expression, (syntax.Function, syntax.Table, syntax.String, syntax.Number))


def _describe_dynamic(expression: syntax.Expression | None) -> str:
    """A short text for a name computed at run time: `"SLASH_" .. …`."""
    if isinstance(expression, syntax.String):
        return f'"{expression.value}"'
    if isinstance(expression, syntax.Name):
        return expression.name
    if isinstance(expression, syntax.BinaryOperation) and expression.operator == "..":
        return f"{_describe_dynamic(expression.left)} .. {_describe_dynamic(expression.right)}"
    return "…"


def analyse(
    chunk: syntax.Chunk,
    file: str,
    widget_methods: Iterable[str] = (),
    event_names: Iterable[str] = (),
) -> list[Reference]:
    """Every host reference of one parsed file, with its guard verdict."""
    return FileAnalysis(chunk, file, frozenset(widget_methods), frozenset(event_names)).run()


def analyse_source(
    text: str,
    file: str = "<string>",
    widget_methods: Iterable[str] = (),
    event_names: Iterable[str] = (),
) -> list[Reference]:
    """Parse and analyse Lua source text; the convenience entry point for tests."""
    return analyse(syntax.parse(text, file), file, widget_methods, event_names)
