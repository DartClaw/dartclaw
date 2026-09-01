// Fitness function: every production `AgentHarness` implementation in the
// workspace calls `AgentHarness.requireStructuredOutputSupport` — not only the
// ones that happen to live in `dartclaw_core`'s harness directory.
//
// Why: `supportsStructuredOutput` defaults to `false` on the contract, which is
// the fail-closed half. The refusal itself is a static helper each `turn()` has
// to call at its entry, because a harness that adopts the contract with
// `implements` inherits no body. A harness that overrides neither still accepts
// an `outputSchema` and drops it silently — a declared output that never reaches
// the provider and never fails. `structured_output_contract_test.dart` proves
// observed behaviour for the harnesses it can construct, and it discovers them
// from `package:dartclaw_core/src/harness/` alone, so an adapter package's
// harness (`dartclaw_acp`) is outside it. This gate is the workspace-wide half:
// it reads source as text and needs no fixture, so a harness in any member is
// covered the moment it is declared.
//
// It enforces the call, not the type system. Sealing `turn()` behind a
// `performTurn()` hook would be the structural guarantee; that reverses a stated
// architecture decision, touches every implementor including out-of-repo SDK
// adopters, and needs an ADR. Until then this is the enforcement, and it is a
// gate rather than a convention.
//
// How to resolve a failure:
//   Call `AgentHarness.requireStructuredOutputSupport(this, outputSchema);` as
//   the first statement of the harness's `turn(...)`, before any provider work.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _allowlistName = 'structured_output_refusal.txt';
const _refusalCall = 'requireStructuredOutputSupport';

final _classDeclaration = RegExp(
  '^$dartDeclarationModifiers'
  r'class\s+(\w+)\b([^{]*)\{',
  multiLine: true,
);
final _extendsHarness = RegExp(r'\bextends\s+\w*Harness\b');
final _implementsClause = RegExp(r'\bimplements\s+([^{]*)');

/// Names of the concrete harness classes [source] declares.
///
/// Abstract classes are skipped: they declare the contract rather than adopt it,
/// and `BaseHarness` is exactly the shape whose subclasses this gate covers.
List<String> harnessDeclarationsIn(String source) {
  final names = <String>[];
  for (final match in _classDeclaration.allMatches(source)) {
    final modifiers = source.substring(match.start, match.start + (match.group(0)!.indexOf('class')));
    if (modifiers.contains('abstract')) continue;
    final header = match.group(2)!;
    if (_extendsHarness.hasMatch(header) || _implementsAgentHarness(header)) names.add(match.group(1)!);
  }
  return names;
}

bool _implementsAgentHarness(String header) {
  final clause = _implementsClause.firstMatch(header);
  if (clause == null) return false;
  return clause
      .group(1)!
      .split(',')
      .map((type) => type.trim().split('<').first.split('.').last)
      .contains('AgentHarness');
}

/// The rule, over already-read sources so it can be exercised against an
/// injected violation: a file declaring N concrete harnesses must carry at
/// least N refusal calls.
List<String> refusalViolations(Map<String, String> sourcesByPath) {
  final violations = <String>[];
  for (final entry in sourcesByPath.entries) {
    final declared = harnessDeclarationsIn(entry.value);
    if (declared.isEmpty) continue;
    final calls = _refusalCall.allMatches(entry.value).length;
    if (calls >= declared.length) continue;
    violations.add(
      '${entry.key}: declares ${declared.length} harness(es) (${declared.join(', ')}) '
      'but calls $_refusalCall $calls time(s)',
    );
  }
  return violations;
}

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, _allowlistName);
  });

  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('the allowlist is well-formed', () {
    assertAllowlistFormat(allowlistFile(repoRoot, _allowlistName), entryFormat: '<path>');
  });

  test('every production harness refuses a schema it cannot enforce', () {
    final sources = <String, String>{};
    for (final member in workspaceMembers(repoRoot)) {
      final lib = Directory('${member.path}/lib');
      if (!lib.existsSync()) continue;
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        sources[relativeTo(file.path, repoRoot)] = file.readAsStringSync();
      }
    }
    final declaring = {
      for (final entry in sources.entries)
        if (harnessDeclarationsIn(entry.value).isNotEmpty) entry.key,
    };
    if (declaring.isEmpty) {
      fail('No harness implementation found in any workspace lib/; the gate would pass vacuously');
    }

    final unexcused = [
      for (final violation in refusalViolations(sources))
        if (!allowlist.containsKey(violation.split(':').first)) violation,
    ];
    if (unexcused.isNotEmpty) {
      fail(
        'Harnesses that can silently drop a declared output schema (see $fitnessReadmePath):\n'
        '  ${unexcused.join('\n  ')}',
      );
    }
  });

  group('the rule fails on an injected violation', () {
    const harnessWithoutRefusal = '''
class RogueHarness extends BaseHarness {
  Future<TurnResult> turn({Map<String, dynamic>? outputSchema}) async => TurnResult();
}
''';
    const harnessWithRefusal = '''
class PoliteHarness implements AgentHarness {
  Future<TurnResult> turn({Map<String, dynamic>? outputSchema}) async {
    AgentHarness.requireStructuredOutputSupport(this, outputSchema);
    return TurnResult();
  }
}
''';

    test('a harness that never calls the refusal is reported by name', () {
      final violations = refusalViolations({'packages/x/lib/rogue.dart': harnessWithoutRefusal});
      expect(violations, hasLength(1));
      expect(violations.single, contains('RogueHarness'));
    });

    test('a harness that calls it is not', () {
      expect(refusalViolations({'packages/x/lib/polite.dart': harnessWithRefusal}), isEmpty);
    });

    test('two harnesses in one file need two calls', () {
      final violations = refusalViolations({'packages/x/lib/both.dart': '$harnessWithRefusal$harnessWithoutRefusal'});
      expect(violations, hasLength(1), reason: 'one call does not cover two adopters');
    });

    test('an abstract harness declares the contract rather than adopting it', () {
      expect(
        refusalViolations({'packages/x/lib/base.dart': 'abstract class BaseHarness implements AgentHarness {}'}),
        isEmpty,
      );
    });
  });
}
