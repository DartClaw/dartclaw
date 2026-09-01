// Fitness function: every published config key must reach production behavior.
//
// What this enforces:
//   Each leaf in the committed config schema has an accessor-shaped identifier
//   outside config declarations and serialization, or a reviewed indirect-consumer rationale.
//
// Why:
//   A schema field with no behavioral consumer leaves operators configuring a feature
//   that no longer exists while the generated guide continues to advertise it.
//
// How to resolve a failure:
//   Option A: restore or name the real behavioral consumer.
//   Option B: for genuinely indirect use, add `<yaml path>  # <consumer rationale>`
//   to allowlist/config_key_consumers.txt. Never allowlist a key merely to make the gate pass.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _configDeclarationPaths = <String>{
  'packages/dartclaw_runtime/lib/src/config/config_serializer.dart',
  'packages/dartclaw_runtime/lib/src/runtime_config.dart',
  'packages/dartclaw_google_chat/lib/src/google_chat_config.dart',
  'packages/dartclaw_signal/lib/src/signal_config.dart',
  'packages/dartclaw_whatsapp/lib/src/whatsapp_config.dart',
  'packages/dartclaw_acp/lib/src/acp_config.dart',
  'packages/dartclaw_acp/lib/src/acp_config_parser.dart',
  'packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart',
  'packages/dartclaw_core/lib/src/harness/harness_config.dart',
  'packages/dartclaw_core/lib/src/scoping/live_scope_config.dart',
};

void main() {
  late Allowlist allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'config_key_consumers.txt');
  });

  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required consumer rationales', () {
    final file = allowlistFile(repoRoot, 'config_key_consumers.txt');
    assertAllowlistFormat(file, entryFormat: '<yaml path>');
    final adminLine = file.readAsLinesSync().singleWhere(
      (line) => line.trimLeft().startsWith('governance.admin_senders  # '),
    );
    final adminRationale = adminLine.substring(adminLine.indexOf('  # ') + 4);
    expect(adminRationale, contains('GovernanceConfig.isAdmin'));
    expect(adminRationale, contains('/stop'));
    expect(adminRationale, contains('reserved-command'));
  });

  test('consumer classification fails missing keys and stale exceptions', () {
    const allowlisted = {'feature.consumed_fixture', 'feature.indirect_fixture'};
    final gaps = _consumerGaps(
      const ['feature.consumed_fixture', 'feature.indirect_fixture', 'feature.missing_fixture'],
      'final consumedFixture = config.consumedFixture;',
      allowlisted.contains,
    );

    expect(gaps.stale, ['feature.consumed_fixture']);
    expect(gaps.missing, ['feature.missing_fixture']);
  });

  test('schema leaves have direct or reviewed indirect consumers', () {
    final schema =
        jsonDecode(File('$repoRoot/schemas/dartclaw.schema.json').readAsStringSync()) as Map<String, Object?>;
    final paths = <String>[];
    _collectLeafPaths(schema, const [], paths);
    final sources = <String>[];
    for (final file in productionDartFiles(repoRoot)) {
      final relative = relativeTo(file.path, repoRoot);
      if (_isConfigDeclaration(relative)) continue;
      sources.add(file.readAsStringSync());
    }
    final joinedSources = sources.join('\n');
    final gaps = _consumerGaps(paths, joinedSources, allowlist.containsKey);
    expect(
      gaps.stale,
      isEmpty,
      reason: 'Stale config consumer allowlist entries now have direct consumers: ${gaps.stale.join(', ')}',
    );
    expect(
      gaps.missing,
      isEmpty,
      reason:
          'Schema keys without a production consumer or allowlist rationale:\n  ${gaps.missing.join('\n  ')}\n'
          'See $fitnessReadmePath and allowlist/config_key_consumers.txt.',
    );
  });
}

({List<String> missing, List<String> stale}) _consumerGaps(
  Iterable<String> paths,
  String source,
  bool Function(String path) isAllowlisted,
) {
  final missing = <String>[];
  final stale = <String>[];
  for (final path in paths) {
    final identifier = _lowerCamel(path.split('.').last.replaceAll('<name>', ''));
    final directlyConsumed = identifier.isNotEmpty && _hasAccessor(source, identifier);
    if (directlyConsumed) {
      if (isAllowlisted(path)) stale.add(path);
    } else if (!isAllowlisted(path)) {
      missing.add(path);
    }
  }
  return (missing: missing, stale: stale);
}

bool _isConfigDeclaration(String path) {
  if (_configDeclarationPaths.contains(path)) return true;
  return path.startsWith('packages/dartclaw_kernel/lib/src/config_') ||
      (path.startsWith('packages/dartclaw_kernel/lib/src/') && path.endsWith('_config.dart'));
}

void _collectLeafPaths(Map<String, Object?> schema, List<String> segments, List<String> paths) {
  final properties = schema['properties'];
  if (properties is Map<String, dynamic>) {
    for (final entry in properties.entries) {
      _collectLeafPaths(entry.value as Map<String, Object?>, [...segments, entry.key], paths);
    }
  }
  final additional = schema['additionalProperties'];
  if (additional is Map<String, dynamic>) {
    final entrySchema = additional.cast<String, Object?>();
    if (entrySchema['properties'] is Map && (entrySchema['properties'] as Map).isNotEmpty) {
      _collectLeafPaths(entrySchema, [...segments, '<name>'], paths);
    } else if (segments.isNotEmpty) {
      paths.add([...segments, '<name>'].join('.'));
    }
  } else if (additional == true && segments.isNotEmpty) {
    paths.add(segments.join('.'));
  }
  if (segments.isNotEmpty && properties is! Map && additional is! Map && additional != true) {
    paths.add(segments.join('.'));
  }
}

String _lowerCamel(String snakeCase) {
  final parts = snakeCase.split('_');
  return parts.first +
      parts.skip(1).map((part) => part.isEmpty ? '' : '${part[0].toUpperCase()}${part.substring(1)}').join();
}

bool _hasAccessor(String source, String identifier) {
  final capitalized = '${identifier[0].toUpperCase()}${identifier.substring(1)}';
  return RegExp('(?:^|[^A-Za-z0-9_])(?:${RegExp.escape(identifier)}|[A-Za-z][A-Za-z0-9_]*$capitalized)(?![A-Za-z0-9_])')
      .hasMatch(source);
}
