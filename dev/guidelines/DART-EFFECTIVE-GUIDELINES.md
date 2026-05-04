# Effective Dart Guidelines

Condensed best practices from official Dart documentation. Applies to all pure Dart and Flutter projects.

**Sources**: [Effective Dart](https://dart.dev/effective-dart) (style, documentation, usage, design), [Language Tour](https://dart.dev/language), [Linter Rules](https://dart.dev/tools/linter-rules)


## Style

### Naming Conventions

| Pattern | Used for |
|---------|----------|
| `UpperCamelCase` | Classes, enums, typedefs, type parameters, extensions, mixins |
| `lowerCamelCase` | Variables, parameters, functions, methods, **constants** |
| `lowercase_with_underscores` | Packages, directories, source files, import prefixes |

- Constants use `lowerCamelCase` (not `SCREAMING_CAPS`): `const defaultTimeout = 1000;`
- Acronyms > 2 letters capitalize like words: `HttpClient`, `Uri` (not `HTTPClient`)
- Exactly 2-letter acronyms capitalize both: `ID`, `UI`, `IO`
- Don't use prefix notation (`kDefaultTimeout`) or Hungarian notation
- Don't use leading `_` for non-private identifiers (locals, params)
- Use `_` wildcard for unused callback params: `future.then((_) { ... });`

### Import Organization (in order, separated by blank lines)

1. `dart:` imports
2. `package:` imports
3. Relative imports

- Alphabetize within each section
- Use relative imports within `lib/` (between files both inside `lib/`)
- Use `package:` imports when importing `lib/` from outside `lib/` (tests, bin)
- Don't use `package:` imports within the same package's `lib/` directory

### Formatting

- Always use `dart format` — never manually format
- Line length is project-configurable (default 80; set via `dart format -l` or `analysis_options.yaml`)
- Always use curly braces for control flow (even single-line `if`/`else`)
- Use `=` default value syntax (not `:`)


## Documentation

### Doc Comments

- Use `///` for all public APIs (not `/** */` or `//`)
- Start with a brief, single-sentence summary (own paragraph)
- Separate summary from body with a blank line
- Use square bracket references: `[ClassName]`, `[methodName]`, `[paramName]`
- Write in prose — avoid verbose `@param`/`@return` tags
- Document _why_, not _what_ — skip obvious documentation
- Use backtick fences for code blocks (not 4-space indent)
- Don't document `toString()` overrides unless surprising

### When to Document

- **DO** document: public classes, members, top-level functions, typedefs, extensions
- **CONSIDER** documenting: private APIs (if complex), libraries (`library` directive)
- **DON'T** document: self-evident getters/setters, obvious constructors

### Proportionality & Anti-Rot

Doc-comment budget should track **visibility**, not line count of the implementation:

| Tier | Target | Shape |
|------|--------|-------|
| **Exported public API** (re-exported via a package's barrel or meant for downstream consumers) | Full Effective Dart: one-sentence summary, blank line, body with invariants, `[TypeName]` refs, examples if non-trivial | Optimise for pub.dev readers who have no source access |
| **Internal** (`lib/src/`, not re-exported) | One-sentence summary + only the **non-obvious WHY**: invariants, ordering constraints, pre/postconditions the signature can't express | Optimise for a future maintainer who is already reading the file |
| **Private** (`_`-prefixed) | None, unless the WHY is genuinely surprising (e.g. workaround for a specific bug, subtle invariant) | Identifier names and the enclosing class's dartdoc carry the load |

**Anti-rot rules (all tiers):**

- **Drift is worse than absence.** A misleading comment actively misinforms — it's worse than no comment at all. Fix or delete wrong/outdated comments on sight; don't leave them standing because they're "not your area".
- **Don't reference planning history in `///` comments.** Story IDs (`S01`), PR numbers (`#123`), sprint labels, "added for the X flow", or "used by Y" are rot markers — they were meaningful to the author but decay into grep-bait. That context belongs in git history and PR descriptions. If a design choice needs durable justification, link to an ADR instead (`See [ADR-NNN](…)`).
- **Don't restate the control flow the code already shows.** If a method's dartdoc enumerates cases that mirror a `switch` or `if`/`else` chain, the two will drift. Prefer a one-line summary plus **named anchors** (`// Case 1:` / `// Case 2:`) in the body the dartdoc can reference by label.
- **Don't paraphrase identifier names.** `/// The harness factory` on a field named `harnessFactory` is pure noise. Comment only what the name doesn't already convey.
- **Collapse multi-paragraph class docs** on internal classes when a one-liner plus the method-level invariants suffice. Wall-of-text on an `lib/src/` class is a smell.
- **Don't document a consumer's behavior at the definition site.** "X is rewrapped by `ServiceWiring.wire()`" or "called from the Y flow" couples this docstring to a caller that can change independently. Document the contract this method offers; let callers document how they use it.
- **No cleanup-leftover markers.** `// REMOVED …`, `// was: …`, `// previously: …`, and similar tombstones belong in git history. Delete the code, then delete the marker.
- **Every `// TODO` needs an owner or tracking link.** Use `// TODO(name): …` or `// TODO(#123): …`. A bare `// TODO: fix this later` is a promise no one made and no one will keep — either fix it now or open an issue and link it.

**How to apply in practice:**

- When touching any file, apply the Boy Scout Rule: trim verbose internal dartdoc and strip planning-history references opportunistically, even if unrelated to the primary change.
- When adding a new public member in a lint-flipped package (`public_member_api_docs` enabled), write the one-sentence summary first, then only add a body if an invariant or non-obvious WHY exists.
- Private helpers get no dartdoc by default. If you find yourself wanting one, ask whether the method name or enclosing class's dartdoc should carry the explanation instead.
- **Inline `//` comments default to none everywhere.** The tier table above governs `///` dartdoc; inline `//` is not tier-escalated. Write inline only when the WHY is non-obvious — a workaround, hidden constraint, or non-trivial invariant. Code comments tax every reader; pay the tax sparingly.


## Usage

### Collections

- Use collection literals: `var points = <Point>[];` not `List<Point>()`
- Use `.isEmpty`/`.isNotEmpty` (not `.length == 0` or `.length > 0`)
- Use `whereType<T>()` to filter by type (not `where((e) => e is T).cast<T>()`)
- AVOID `forEach` with function literals — use `for` loops or `Iterable.map()` instead (tear-offs like `forEach(print)` are fine)
- Use `List.from()` when intentionally changing type; use `toList()` otherwise
- Use `spread` to merge collections: `[...a, ...b]`

### Strings

- Use adjacent string literals for concatenation (not `+`)
- Use string interpolation: `'Hello, $name'` (not `'Hello, ' + name`)
- Omit `{}` in simple interpolation: `'$name'` not `'${name}'`

### Variables & Types

- Don't explicitly initialize nullable fields/variables to `null` (Dart default-initializes nullable types; non-nullable types require definite initialization)
- Don't use `true`/`false` in equality: `if (flag)` not `if (flag == true)`
- Use type inference for local vars: `var items = <String>[]`
- Annotate types on public APIs: `String greet(String name) => ...`
- Prefer `final` for local variables that aren't reassigned
- Avoid `late` unless truly needed (no eager alternative, field initialized before use)
- Use `var` for locals; use explicit types on uninitialized or public declarations
- Don't annotate inferred parameter types in callbacks: `list.map((e) => e.length)`
- Don't redundantly type-annotate initialized locals

### Functions

- Use tear-offs instead of lambdas: `names.forEach(print)` not `names.forEach((n) => print(n))`
- Use `=>` for single-expression members (not for multi-line or `void` with no return)
- Don't create a lambda when a tear-off will do
- Avoid returning `this` for fluent chaining — use cascade `..` instead

### Null Safety

- Don't use `as` for nullable-to-non-nullable — check first, then use
- Use `??` for default values: `name ?? 'Guest'`
- Use `?.` for null-safe method calls
- Use `!` only when you're certain a value is non-null (sparingly)
- Promote nullable types with null-checks rather than casting
- Use `late` only when you can guarantee initialization before access

### Async

- **PREFER** `async`/`await` over raw `Future` APIs — more readable, better error handling
- **DON'T** use `async` when it has no useful effect (no `await`, no async errors)
- Use `Future<void>` (not `Future<Null>` or bare `Future`)
- Avoid `Completer` — use `async`/`await` instead (except low-level interop)
- Avoid `FutureOr<T>` as return type — use specific `Future<T>` or `T`

### Error Handling

- Throw `Exception` for runtime failures; `Error` for programming bugs
- Use specific `on` clauses: `on FormatException catch (e)` — avoid bare `catch`
- **DON'T** catch `Error` or its subclasses — they indicate bugs, let them propagate
- Use `rethrow` to preserve stack trace (not `throw e`)
- DON'T discard errors from `catch` without `on` clause
- Use `assert` for development-time invariant checks

### Control Flow

- Use `if` with element collections: `[if (condition) item]`
- Use `for` with element collections: `[for (var x in items) x.name]`
- Use `switch` expressions for exhaustive pattern matching (Dart 3.x)
- Prefer pattern matching over `is`/`as` chains


## Design (API Design)

### Naming

- Be consistent: use same term for same concept across API
- Avoid abbreviations (unless universally known: `i`, `id`, `ui`, `http`)
- Put the most descriptive noun last: `List<Element>`, not `ElementList`
- Boolean properties: non-imperative adjectives/verbs — `isEnabled`, `hasData`, `canClose`
- Boolean params: positive, clarifying names — `includeHidden: true` not `hidden: true`
- Methods with side effects: imperative verb — `add()`, `close()`, `refresh()`
- Methods returning values: noun phrase — `elementAt()`, `keys`, `length`
- Conversions: `toX()` for snapshot copies, `asX()` for views/wrappers

### Classes & Types

- Avoid defining single-method abstract classes — use `typedef` for function types instead
- Use `final` on classes not designed for subclassing
- Use `sealed` for exhaustive type hierarchies
- Use `base` to allow extension but prevent implementation
- Don't extend a class unless it was designed for it
- Override `hashCode` whenever you override `==` (maintain contract)
- Make `==` follow math rules: reflexive, symmetric, transitive, consistent

### Parameters

- **AVOID** positional boolean parameters — use named params for clarity
  - Bad: `connect(true)` — Good: `connect(enableTls: true)`
- Use inclusive start, exclusive end for ranges: `substring(1, 3)` means indices 1,2
- Use named params for optional args (especially booleans and multiple optionals)
- Place required positional params first
- Use `required` keyword for mandatory named params

### Type Parameters

- Single-letter mnemonics: `E` (element), `K` (key), `V` (value), `T` (type), `R` (return), `S`/`U` (additional)
- If a type parameter isn't meaningful, `T` is conventional

### Getters & Setters

- Don't wrap fields in trivial getters/setters — Dart fields _are_ the interface
- Use getter for derived/computed values
- Don't define a setter without a corresponding getter
- Avoid returning `this` — use cascade `..` operator instead


## Software Design

Guidance for _internal_ design — how to structure classes, dependencies, and polymorphism. Complements the API Design section above, which covers the public surface.

### Composition vs Inheritance

- **Prefer composition** (hold a field, delegate to it) over inheritance — inheritance couples lifecycle and permits accidental overrides
- Use inheritance only for genuine _is-a_ relationships with shared substitutable behavior
- Use **mixins** (`mixin`, `mixin class`) for _has-capability_ — orthogonal concerns composed into multiple types (e.g. disposable, cacheable)
- Use `implements` to satisfy a contract without inheriting code — every Dart class has an implicit interface
- Don't extend just to share code; extract a helper class or top-level function instead
- A subclass-per-variant is often a smell — a strategy field or a `sealed` hierarchy may fit better

### Polymorphism — the Dart Menu

Dart gives you several polymorphism mechanisms. Pick the lightest one that fits:

| Mechanism | When to use |
|-----------|-------------|
| `typedef` function type | Single-method strategy — `typedef Parser = Result Function(String)` |
| `sealed class` + pattern match | Closed, known set of variants; compiler checks exhaustiveness |
| `abstract interface class` | Open extension point with multi-method contract; third parties may implement |
| `mixin` / `mixin class` | Orthogonal capability applied to many unrelated types |
| `extension` | Add methods to types you don't own without subclassing |
| Enhanced `enum` | Closed set of named values with behavior |

- Start with a `typedef` or a `sealed` type; reach for abstract classes only when you genuinely have a multi-method contract with open extension
- Avoid single-method abstract classes — the `typedef` is simpler and composes better
- Don't `implements` a concrete class you don't own — its private/implicit invariants can break between versions; prefer declaring your own interface and adapting

### Dependency Management

- **Constructor injection** is the default — pass dependencies in, don't look them up globally
- Depend on narrow interfaces (your own `abstract interface class`) when testing boundaries or multiple implementations matter; depend on concrete classes otherwise (don't create interfaces pre-emptively)
- Avoid singletons and static mutable state — they make tests order-dependent and hide coupling; pass instances explicitly
- Keep constructors **side-effect-free** — do I/O in a named `init()` / `start()` method or a lazy getter, not in `MyService()`
- `late final` is fine for lazy wiring, but only when the initializer is pure and order-independent
- Don't reach for a DI framework — Dart's constructors, closures, and top-level providers cover most cases; frameworks add indirection with little payoff at typical project sizes

### Encapsulation & Cohesion

- Fields default to `_private`; expose only what callers need, via getters or methods
- **Single Responsibility**: a class should have one reason to change — split along axes that vary independently (e.g. parsing vs transport vs caching)
- If a method doesn't use `this`, it's probably a top-level function or `static` — don't pad classes with stateless utilities
- Long parameter lists (>4) or several optional booleans signal an options / request record or `final class` is overdue
- Co-locate behavior with the data it operates on — methods on the class, not external utilities that take the class as an argument (aka "feature envy")
- A file / library over ~500 lines, or a class with >15 public members, is a refactor hint — look for an extractable collaborator

### Immutability & Value Objects

- Default to `final class` and `final` fields; make mutation explicit and localized
- For value-equal data, use **records** (`(String name, int age)`) for small/transient shapes, or a `final class` with explicit `==` / `hashCode` for named, reusable ones
- Prefer `const` constructors where possible — compile-time shared instances, zero allocation
- Don't expose mutable internal collections — return `List.unmodifiable(...)` or `UnmodifiableListView`
- Use a `copyWith` method for "change one field, produce a new value" — idiomatic for immutable value types
- For larger value-type hierarchies, consider `package:freezed` (codegen for `==`, `copyWith`, pattern matching) — adopt only if the project is already set up for codegen

### Common Patterns — Dart-Idiomatic Forms

Recognize these before reinventing them — several "GoF" patterns collapse to a language feature in Dart:

- **Strategy** — a function (`typedef`) passed as a parameter; only reach for an interface when the strategy has state or multiple methods
- **Factory** — use `factory` constructors; supports caching, polymorphic construction, returning subtypes. No separate factory class needed
- **Observer / Pub-Sub** — `Stream` and `StreamController` (use `.broadcast()` for multi-listener). Don't hand-roll listener lists
- **Iterator / Generator** — `sync*` / `async*` generators, or implement `Iterable` / `Iterator`
- **Adapter** — wrap the foreign type in a class that `implements` your interface; for pure method-shape adaptation, an `extension` may suffice
- **Decorator** — compose by holding the inner instance and implementing the same interface; forward unchanged methods, augment the rest
- **Builder** — usually unnecessary: named params + `copyWith` cover most cases. Use only for genuinely multi-step construction with mid-build validation
- **Repository / Gateway** — narrow interface for data access; keep persistence, caching, and serialization behind it
- **Null Object** — often replaced by Dart's null safety and `?.` / `??`; introduce only when a default behavior must participate in polymorphism


## Modern Dart 3.x Features

### Patterns

- Use pattern matching in switch expressions for exhaustive, concise code
- Destructure records: `var (name, age) = getNameAndAge();`
- Use object patterns: `case Rect(width: var w, height: var h):`
- Use guard clauses: `case int n when n > 0:`

### Records

- Use for multiple return values: `(String, int) parse(String s) => ...`
- Access positional fields: `record.$1`, `record.$2`
- Access named fields: `record.name`
- Records are immutable and value-equal by structure

### Sealed Classes & Exhaustiveness

- Use `sealed` for closed type hierarchies (compiler checks exhaustiveness)
- Pattern match on sealed types in switch — no default needed
- Direct subtypes must be in same library

### Enhanced Enums

- Add fields, methods, and implement interfaces on enums
- Use for fixed sets of known values with behavior


## Linter Configuration

Recommended `analysis_options.yaml`:
```yaml
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
  errors:
    missing_return: error
    dead_code: warning
```

Key recommended linter rules (beyond `package:lints`):
- `prefer_final_locals` — encourages immutability
- `avoid_print` — use proper logging
- `unawaited_futures` — catch missing awaits
- `use_super_parameters` — Dart 2.17+ constructor shorthand
- `unnecessary_lambdas` — use tear-offs
- `prefer_single_quotes` — consistency
- `prefer_const_constructors` — Flutter only; compile-time const optimization
