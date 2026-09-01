// Fitness function: one production type name is declared in one workspace member.
//
// What this enforces:
//   A public `class`, `enum`, `mixin`, `extension type` or `typedef` name
//   declared in one member's `lib/` is not declared again in another member's.
//   Two declarations of one name are two answers with no arbiter, and they
//   drift — the second-implementation defect class in ADR-054 and in
//   dev/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md § Review Defect Classes.
//
// Scope is every workspace member with a `lib/`, **apps included**: scanning
// `packages/` alone misses a duplicate that lands in the application.
//
// A `typedef X = other.X;` re-alias is not a second declaration — it is a
// re-export under the owner's own name, and it is skipped by the scan rather
// than exempted by the allowlist.
//
// The pre-milestone baseline was TEN cross-package duplicate names: the turn
// manager, runner, outcome and status types, the harness config, the busy-turn
// exception, the reserved command handler, the Google JWT verifier, a
// validation error and a Windows process-tree terminator. The seeded allowlist
// must stay below that number, and each entry states why it survives.
//
// How to resolve a failure:
//   Rename one of the two, or move the shared type down to the member both
//   already depend on. Allowlist only a duplicate you can justify in one line.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _allowlistFile = 'no_second_implementation.txt';

/// The recorded size of this gate's exemption set. It is the actual, not a
/// budget: the milestone began from ten cross-package duplicates, and pinning
/// the ratchet at that number would leave four free slots for new ones. Lower it
/// in the change that resolves a duplicate; raising it needs the same review a
/// raised LOC ceiling does.
const _recordedExemptionCount = 2;

/// What the exemption set started from, kept as provenance for the number above.
const _preMilestoneDuplicateCount = 10;

// `extension` is included: a public extension name collides on import exactly
// as a class does. `extension on X` (anonymous) has no name and does not match.
final _declaration = RegExp(
  '^$dartDeclarationModifiers'
  r'(?:class|enum|mixin|typedef|extension\s+type|extension\s+(?!on\b))\s*([A-Za-z_]\w*)',
);

/// `typedef Foo = bar.Foo;` — a re-export under the owner's own name.
final _sameNameAlias = RegExp(r'^\s*typedef\s+([A-Za-z_]\w*)\s*=\s*\w+\.\1\s*;');

class Declaration {
  const new(this.name, this.member, this.location);

  final String name;
  final String member;
  final String location;
}

List<Declaration> productionDeclarations(String repoRoot) {
  final declarations = <Declaration>[];
  for (final member in workspaceMembers(repoRoot)) {
    final lib = Directory('${member.path}/lib');
    if (!lib.existsSync()) continue;
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_sameNameAlias.hasMatch(lines[i])) continue;
        final name = _declaration.firstMatch(lines[i])?.group(1);
        if (name == null || name.startsWith('_')) continue;
        declarations.add(Declaration(name, member.name, '${relativeTo(file.path, repoRoot)}:${i + 1}'));
      }
    }
  }
  return declarations;
}

/// Names declared in more than one member, with every declaring site.
Map<String, List<Declaration>> crossMemberDuplicates(List<Declaration> declarations) {
  final byName = <String, List<Declaration>>{};
  for (final declaration in declarations) {
    (byName[declaration.name] ??= []).add(declaration);
  }
  return {
    for (final entry in byName.entries)
      if (entry.value.map((d) => d.member).toSet().length > 1) entry.key: entry.value,
  };
}

void main() {
  late String repoRoot;
  late Allowlist allowlist;
  late Map<String, List<Declaration>> duplicates;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, _allowlistFile);
    duplicates = crossMemberDuplicates(productionDeclarations(repoRoot));
  });

  // An entry naming a duplicate that no longer exists guards nothing.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, _allowlistFile), entryFormat: '<TypeName>');
  });

  test('the scan finds declarations in every member with a lib/', () {
    // A silently-empty scan would make the assertion below vacuously true.
    final declarations = productionDeclarations(repoRoot);
    final scanned = declarations.map((d) => d.member).toSet();
    // Keyed on `lib/src/`, not `lib/`: the umbrella package is a barrel of
    // re-exports and declares nothing, which is correct, not an empty scan.
    final expected = {
      for (final member in workspaceMembers(repoRoot))
        if (Directory('${member.path}/lib/src').existsSync()) member.name,
    };
    expect(scanned, equals(expected), reason: 'a member with a lib/src/ contributed no declaration');
    expect(
      scanned,
      contains('dartclaw_cli'),
      reason: 'apps are in scope; packages/ alone misses an app-side duplicate',
    );
  });

  test('no production type name is declared in two workspace members', () {
    final violations = [
      for (final entry in duplicates.entries)
        if (!allowlist.containsKey(entry.key))
          '${entry.key} declared in ${entry.value.map((d) => d.member).toSet().toList()..sort()}:\n'
              '${entry.value.map((d) => '      ${d.location}').join('\n')}',
    ]..sort();
    if (violations.isNotEmpty) {
      fail(
        'Production type names declared in more than one workspace member:\n'
        '  ${violations.join('\n  ')}\n'
        'Rename one, or move the shared type down to the member both depend on. '
        'See $fitnessReadmePath.',
      );
    }
  });

  test('the exemption set only shrinks', () {
    expect(
      allowlist.length,
      lessThanOrEqualTo(_recordedExemptionCount),
      reason:
          'the recorded exemption count is the actual, not a budget: it started at '
          '$_preMilestoneDuplicateCount and is now $_recordedExemptionCount. Resolve the duplicate, '
          'or lower _recordedExemptionCount in the change that removes an entry',
    );
    expect(
      _recordedExemptionCount,
      lessThan(_preMilestoneDuplicateCount),
      reason: 'the recorded count must stay below the pre-milestone baseline it ratchets down from',
    );
  });

  group('the rule fails on an injected violation', () {
    const declarations = [
      Declaration('SharedThing', 'dartclaw_core', 'packages/dartclaw_core/lib/src/a.dart:3'),
      Declaration('SharedThing', 'dartclaw_cli', 'apps/dartclaw_cli/lib/src/b.dart:9'),
      Declaration('LocalThing', 'dartclaw_core', 'packages/dartclaw_core/lib/src/c.dart:1'),
      Declaration('LocalThing', 'dartclaw_core', 'packages/dartclaw_core/lib/src/d.dart:1'),
    ];

    test('a name declared in two members is reported with both members', () {
      final found = crossMemberDuplicates(declarations);
      expect(found.keys, ['SharedThing']);
      expect(found['SharedThing']!.map((d) => d.member).toSet(), {'dartclaw_core', 'dartclaw_cli'});
    });

    test('a duplicate landing in an app is caught, not only one between packages', () {
      expect(crossMemberDuplicates(declarations)['SharedThing']!.map((d) => d.location), contains(contains('apps/')));
    });

    test('the same name twice inside one member is not a cross-member duplicate', () {
      expect(crossMemberDuplicates(declarations).containsKey('LocalThing'), isFalse);
    });
  });

  group('the declaration scan', () {
    test('reads every declaration keyword, with and without modifiers', () {
      for (final line in const [
        'class Foo {',
        'abstract class Foo {',
        'final class Foo implements Bar {',
        'sealed class Foo {',
        'enum Foo { a, b }',
        'mixin Foo on Bar {',
        'typedef Foo = void Function();',
        'extension type Foo(int value) {',
      ]) {
        expect(_declaration.firstMatch(line)?.group(1), 'Foo', reason: line);
      }
    });

    test('skips private declarations and indented (nested) ones', () {
      expect(_declaration.firstMatch('class _Foo {')?.group(1), '_Foo');
      expect(_declaration.hasMatch('  class Foo {'), isFalse);
    });

    test('reads a named extension but not an anonymous one', () {
      expect(_declaration.firstMatch('extension IterableX on Iterable<int> {')?.group(1), 'IterableX');
      expect(_declaration.firstMatch('extension type Foo(int v) {')?.group(1), 'Foo');
      expect(_declaration.hasMatch('extension on Iterable<int> {'), isFalse);
    });

    test('skips a same-name re-alias but not an alias to a different name', () {
      expect(_sameNameAlias.hasMatch('typedef TurnStatus = core.TurnStatus;'), isTrue);
      expect(_sameNameAlias.hasMatch('typedef TurnStatus = core.SomethingElse;'), isFalse);
      expect(_sameNameAlias.hasMatch('typedef TurnStatus = void Function();'), isFalse);
    });
  });
}
