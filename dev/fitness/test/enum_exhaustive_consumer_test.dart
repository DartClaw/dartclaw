// Fitness function: selected enum/event consumers must enumerate every status value.
//
// How to resolve a failure:
//   Update the named consumer to handle the new enum value. If a consumer is
//   deliberately value-derived and does not enumerate values, add
//   `<file>:<EnumName>  # <rationale>` to enum_exhaustive_consumer.txt.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

/// Enum consumers that must branch on every value, with the declaration each
/// value set is read from. The values are never written down here: a copy is a
/// second answer that goes quiet the day the enum grows.
const _targets = [
  (
    enumName: 'WorkflowRunStatus',
    declaration: 'packages/dartclaw_kernel/lib/src/workflow_run_status.dart',
    consumers: [
      'packages/dartclaw_runtime/lib/src/templates/workflow_detail.dart',
      'packages/dartclaw_runtime/lib/src/api/task_sse_routes.dart',
      'packages/dartclaw_workflow/lib/src/workflow/workflow_view_helpers.dart',
      'apps/dartclaw_cli/lib/src/commands/workflow/api_workflow_connection.dart',
      'apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart',
    ],
  ),
  (
    enumName: 'TaskStatus',
    declaration: 'packages/dartclaw_core/lib/src/task/task_status.dart',
    consumers: ['packages/dartclaw_workflow/lib/src/workflow/workflow_view_helpers.dart'],
  ),
  (
    enumName: 'WorkerState',
    declaration: 'packages/dartclaw_core/lib/src/worker/worker_state.dart',
    // The operator-health projection is the only consumer that branches on
    // worker states; every surface reporting health renders its answer.
    consumers: ['packages/dartclaw_runtime/lib/src/health/health_service.dart'],
  ),
];

/// Where the sealed `DartclawEvent` hierarchy is declared. The concrete leaves
/// are derived from it rather than listed, for the same reason as the enums.
const _eventsDir = 'packages/dartclaw_core/lib/src/events';

/// The alert classifier is the only `DartclawEvent` consumer in `alerts/`: it
/// decides an alert's type, severity and content together, so a new event type
/// has exactly one place that must consciously classify it (ADR-057).
const _eventConsumers = ['packages/dartclaw_runtime/lib/src/alerts/alert_classifier.dart'];

// A consumer that must stay exhaustive cannot carry a wildcard arm: `_ =>`
// compiles, keeps every test green, and silently answers for every future
// value. That is the property ADR-057 keeps DartclawEvent sealed for, and the
// property an enum switch has for free until a wildcard takes it away.
const _wildcardFreeConsumers = [
  'packages/dartclaw_runtime/lib/src/alerts/alert_classifier.dart',
  'packages/dartclaw_runtime/lib/src/health/health_service.dart',
];

// A file that cannot name a DartclawEvent subtype cannot switch on one. Alert
// rendering is downstream of classification and must stay event-blind.
const _eventBlindFiles = ['packages/dartclaw_runtime/lib/src/alerts/alert_formatter.dart'];

/// The concrete `DartclawEvent` subtypes, by transitive closure over the sealed
/// hierarchy: a `sealed` or `abstract` link is an intermediate, every other
/// class reached from `DartclawEvent` is a leaf a consumer must classify.
Set<String> _concreteEventSubtypes(String repoRoot) {
  final parents = <String, String>{};
  final intermediates = <String>{};
  final dir = Directory('$repoRoot/$_eventsDir');
  if (!dir.existsSync()) fail('$_eventsDir does not exist; DartclawEvent subtypes cannot be read');
  final declaration = RegExp('^($dartDeclarationModifiers)class\\s+(\\w+)\\s+extends\\s+(\\w+)', multiLine: true);
  for (final file in dir.listSync().whereType<File>().where((file) => file.path.endsWith('.dart'))) {
    final source = withoutCommentsAndStrings(file.readAsStringSync());
    for (final match in declaration.allMatches(source)) {
      final name = match.group(2)!;
      parents[name] = match.group(3)!;
      if (match.group(1)!.contains('sealed') || match.group(1)!.contains('abstract')) intermediates.add(name);
    }
  }

  bool descendsFromEvent(String name) {
    for (var current = parents[name], hops = 0; current != null && hops < 16; current = parents[current], hops++) {
      if (current == 'DartclawEvent') return true;
    }
    return false;
  }

  final leaves = {
    for (final name in parents.keys)
      if (!intermediates.contains(name) && descendsFromEvent(name)) name,
  };
  if (leaves.isEmpty) fail('$_eventsDir: no concrete DartclawEvent subtype was parsed; the scan read nothing');
  return leaves;
}

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'enum_exhaustive_consumer.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'enum_exhaustive_consumer.txt'));
  });

  test('enum consumers branch on every value the declaration carries', () {
    final violations = <String>[];

    // Comments and strings are stripped first: a value named in a doc comment
    // or in an operator message is a mention, not a branch, and reading one as
    // the other is how a dropped arm passes.
    String code(String consumer) => withoutCommentsAndStrings(File('$repoRoot/$consumer').readAsStringSync());

    for (final target in _targets) {
      final values = enumValuesIn(repoRoot, target.declaration, target.enumName);
      for (final consumer in target.consumers) {
        final missing = unbranchedValues(target.enumName, values, code(consumer));
        // Consulted only on a real gap, so an entry for a consumer that now
        // handles every value reads as stale instead of silent.
        if (missing.isEmpty || allowlist.containsKey('$consumer:${target.enumName}')) continue;
        violations.addAll([for (final value in missing) '${target.enumName}.$value not handled in $consumer']);
      }
    }

    final eventSubtypes = _concreteEventSubtypes(repoRoot);
    for (final consumer in _eventConsumers) {
      final key = '$consumer:DartclawEvent';
      final content = code(consumer);
      for (final subtype in eventSubtypes) {
        if (!content.contains(subtype) && !allowlist.containsKey(key)) {
          violations.add('$subtype not handled in $consumer');
        }
      }
    }

    if (violations.isNotEmpty) {
      fail('Enum consumer exhaustiveness violations:\n  ${violations.join('\n  ')}');
    }
  });

  test('exhaustive consumers carry no wildcard arm', () {
    for (final consumer in _wildcardFreeConsumers) {
      expect(
        withoutCommentsAndStrings(File('$repoRoot/$consumer').readAsStringSync()),
        isNot(contains('_ =>')),
        reason:
            '$consumer must name every value explicitly. A `_ =>` arm turns "a new value must be '
            'handled" into "a new value takes the fallback" with no compile error (ADR-057).',
      );
    }
  });

  // Read raw, unlike every other scan here: the thing being looked for is an
  // import URI, which is a string literal and would be stripped away.
  test('event-blind files cannot name an event type', () {
    for (final file in _eventBlindFiles) {
      expect(
        File('$repoRoot/$file').readAsStringSync(),
        isNot(contains('package:dartclaw_core')),
        reason:
            '$file must not import dartclaw_core: with no DartclawEvent subtype in scope, no switch '
            'over an event can be reintroduced under any parameter name.',
      );
    }
  });

  // Every registration above rests on this scan, so run it over a planted gap
  // rather than reading a green run over a satisfied tree as proof it works.
  group('the rule fails on an injected violation', () {
    const wildcarded =
        "switch (state) { WorkerState.stopped => 'unhealthy', WorkerState.crashed || null => 'degraded', _ => 'x' }";

    test('values left to a wildcard are reported, and only those values', () {
      expect(unbranchedValues('WorkerState', const ['idle', 'busy', 'stopped'], wildcarded), equals(['idle', 'busy']));
    });

    test('a consumer branching on every value reports nothing', () {
      expect(unbranchedValues('WorkerState', const ['stopped', 'crashed'], wildcarded), isEmpty);
    });

    test('a value named only as a bare identifier is not read as a branch', () {
      expect(unbranchedValues('WorkerState', const ['idle'], 'if (state.name == idle) return;'), equals(['idle']));
    });
  });
}

/// The enum values a consumer has to branch on but does not.
///
/// The rule itself, extracted so the injected-violation group can run it over
/// synthetic source instead of over a tree that already satisfies it.
List<String> unbranchedValues(String enumName, Iterable<String> values, String code) => [
  for (final value in values)
    if (!code.contains('$enumName.$value')) value,
];
