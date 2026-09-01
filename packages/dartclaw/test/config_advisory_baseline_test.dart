import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show loadDartclawConfig;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Regenerate from the workspace root with:
// DARTCLAW_UPDATE_CONFIG_ADVISORY_GOLDEN=1 dart test packages/dartclaw/test/config_advisory_baseline_test.dart
//
// GitHub's extension parser is registered before load. The canonical server
// seam then resolves channel config in the pinned whatsapp, signal, googlechat
// order. Messages are copied unchanged except for a VM-owned exception body
// inside a GitHub extension warning, which is replaced with its runtime type.
const _updateVariable = 'DARTCLAW_UPDATE_CONFIG_ADVISORY_GOLDEN';
const _syntheticConfigPath = '/dartclaw/baseline/dartclaw.yaml';
const _pinnedEnvironment = {
  'HOME': '/dartclaw/home',
  'USERPROFILE': '/dartclaw/home',
  'GITHUB_TOKEN': 'pinned-github-token',
  'DARTCLAW_TOKEN': 'pinned-dartclaw-token',
};
const _channelOrder = [ChannelType.whatsapp, ChannelType.signal, ChannelType.googlechat];
const _corpusPaths = [
  'examples/dev.yaml',
  'examples/personal-assistant.yaml',
  'examples/production.yaml',
  'dev/testing/profiles/channels/data/dartclaw.yaml',
  'dev/testing/profiles/governance/data/dartclaw.yaml',
  'dev/testing/profiles/plain/data/dartclaw.yaml',
  'dev/testing/profiles/visual/data/dartclaw.yaml',
  'dev/testing/profiles/workflows/data/dartclaw.yaml',
];
const _expectedCanaryLines = <String, String>{
  'workflow.approvals#type-nonstring': '  [blocking] Invalid type for workflow.approvals: "int" – using default manual',
  'workflow.approvals#non-member':
      '  [blocking] Invalid value for workflow.approvals: "__dartclaw_not_a_member__" '
      '(allowed: manual, auto-on-stall, auto) – using default manual',
  'memory#scalar': '  [blocking] Invalid type for memory: "int" — using defaults',
  'context.max_result_bytes#type-string': '  [blocking] Invalid type for max_result_bytes: "String" — using default',
  'channels.signal.dm_access#type-nonstring': '  [blocking] Invalid type for signal.dm_access: "int" — using default',
};

void main() {
  late Directory repoRoot;
  late File goldenFile;
  late List<_CaseRecord> records;
  late String report;
  late Set<String> corpusEnvironmentKeys;

  setUpAll(() async {
    DartclawConfig.clearExtensionParsers();
    ensureGitHubWebhookConfigRegistered();
    repoRoot = await _resolveRepoRoot();
    goldenFile = File('${repoRoot.path}/packages/dartclaw/test/goldens/config_advisory_baseline.txt');
    corpusEnvironmentKeys = _corpusEnvironmentKeys(repoRoot);
    records = await _generateRecords(repoRoot);
    report = _renderReport(records);
  });

  tearDownAll(DartclawConfig.clearExtensionParsers);

  group('config advisory fidelity baseline', () {
    test('S01 S07 fresh report is byte-identical and host-independent', () {
      final portabilityFailures = _portabilityFailures(
        report,
        repoRoot,
        environment: Platform.environment,
        relevantEnvironmentKeys: corpusEnvironmentKeys,
      );
      expect(portabilityFailures, isEmpty, reason: portabilityFailures.join('\n'));

      if (Platform.environment[_updateVariable] == '1') {
        goldenFile.parent.createSync(recursive: true);
        goldenFile.writeAsStringSync(report, flush: true);
      }

      expect(goldenFile.existsSync(), isTrue, reason: 'Regenerate with the command in this test file header.');
      final difference = _firstDifference(goldenFile.readAsStringSync(), report);
      expect(difference, isNull, reason: difference);

      final byKey = {for (final record in records) record.key: record};
      expect(byKey['examples/personal-assistant.yaml#corpus']!.lines, [
        '  [blocking] Agent "cron" has no tools configured – no sandbox allowlist will be enforced',
      ]);
      expect(byKey['dev/testing/profiles/visual/data/dartclaw.yaml#corpus']!.lines, [
        '  [blocking] Missing required google_chat.service_account when channel is enabled',
      ]);
      final silentCorpus = _corpusPaths
          .where((path) => byKey['$path#corpus']!.lines.single == '  (none)')
          .toList(growable: false);
      expect(silentCorpus, hasLength(6));
    });

    test('S05 canonical channel resolution and GitHub registration are live', () {
      expect(ChannelType.values.where((type) => type != ChannelType.web), orderedEquals(_channelOrder));
      expect(DartclawConfig.registeredExtensionKeysForTesting(), contains('github'));

      final byKey = {for (final record in records) record.key: record};
      expect(
        byKey['channels.signal.dm_access#type-nonstring']!.lines,
        contains('  [blocking] Invalid type for signal.dm_access: "int" — using default'),
      );
      expect(
        byKey['github#enabled-without-secret']!.lines,
        contains('  [blocking] github.webhook_secret is missing while github.enabled=true'),
      );
    });

    test('S02 S03 exact positional canaries preserve both byte traps', () {
      final golden = goldenFile.readAsStringSync();
      expect(_canaryFailures(golden), isEmpty);

      for (final entry in _expectedCanaryLines.entries) {
        final suffixMutant = _mutateCanaryLine(golden, entry.key, '${entry.value} unexpected-suffix');
        expect(_canaryFailures(suffixMutant), [entry.key], reason: entry.key);
      }

      const typeKey = 'workflow.approvals#type-nonstring';
      final typeDashMutant = _mutateCanaryLine(
        golden,
        typeKey,
        _expectedCanaryLines[typeKey]!.replaceFirst(' – ', ' — '),
      );
      expect(_canaryFailures(typeDashMutant), [typeKey]);

      const memberKey = 'workflow.approvals#non-member';
      final memberDashMutant = _mutateCanaryLine(
        golden,
        memberKey,
        _expectedCanaryLines[memberKey]!.replaceFirst(' – ', ' — '),
      );
      expect(_canaryFailures(memberDashMutant), [memberKey]);

      const memoryKey = 'memory#scalar';
      final pluralMutant = _mutateCanaryLine(
        golden,
        memoryKey,
        _expectedCanaryLines[memoryKey]!.replaceFirst('using defaults', 'using default'),
      );
      expect(_canaryFailures(pluralMutant), [memoryKey]);

      final unrelatedMutant = golden.replaceFirst(
        'Agent "cron" has no tools configured – no sandbox allowlist will be enforced',
        'Agent "cron" has no tools configured — no sandbox allowlist will be enforced',
      );
      expect(_canaryFailures(unrelatedMutant), isEmpty);
    });

    test('TI02 GitHub extension redaction preserves the actual exception runtime type', () {
      const typeErrorCase = _Case('github.webhook_secret#type-nonstring', '{"github":{"webhook_secret":1}}');
      final error = _githubExtensionError(typeErrorCase.document);
      expect(error, isA<TypeError>());

      const emitted = 'Error parsing extension "github": VM-owned payload — storing as raw data';
      expect(
        _redactVmError(emitted, error),
        'Error parsing extension "github": ${error.runtimeType} — storing as raw data',
      );
      final stateError = StateError('different failure class');
      expect(
        _redactVmError(emitted, stateError),
        'Error parsing extension "github": ${stateError.runtimeType} — storing as raw data',
      );

      final record = _record(typeErrorCase);
      expect(record.lines, [
        '  [blocking] Error parsing extension "github": ${error.runtimeType} — storing as raw data',
      ]);
    });

    test('S04 S06 silent and throwing outcomes are explicit without truncating the matrix', () {
      final byKey = {for (final record in records) record.key: record};
      expect(byKey['tasks.artifact_retention_days#above-max']!.lines, ['  (none)']);
      expect(byKey['guard_audit.max_retention_days#above-max']!.lines, ['  (none)']);

      expect(byKey['memory.max_bytes#below-min']!.lines.single, startsWith('  THREW: '));
      expect(byKey['memory.pruning.archive_after_days#below-min']!.lines.single, startsWith('  THREW: '));
      expect(byKey['mcp_servers#type-nonmap']!.lines.single, startsWith('  THREW: '));
      expect(records.last.key, _allCases().last.key);
      expect(records, hasLength(_corpusPaths.length + _allCases().length));
    });

    test('TI02 generated key set independently matches every registry field arm and prefix', () {
      final generatedKeys = records
          .where((record) => !record.key.endsWith('#corpus'))
          .map((record) => record.key)
          .toList();
      final expectedKeys = _expectedMatrixKeys();
      expect(generatedKeys, orderedEquals(expectedKeys));
      expect(generatedKeys, orderedEquals([...generatedKeys]..sort()));
      expect(generatedKeys.toSet(), hasLength(generatedKeys.length));
      expect(generatedKeys, everyElement(matches(RegExp(r'^[A-Za-z0-9_.]+#[a-z-]+$'))));

      expect(
        generatedKeys,
        containsAll(<String>{
          'workflow.approvals#type-nonstring',
          'workflow.approvals#non-member',
          'mcp_servers#type-nonmap',
          'memory#scalar',
          'channels#scalar',
          'tasks.budget.warning_threshold#type-nonnumber',
        }),
      );

      final representedTypes = <ConfigFieldType>{};
      for (final field in ConfigMeta.fields.values) {
        if (generatedKeys.any((key) => key.startsWith('${field.yamlPath}#type-'))) {
          representedTypes.add(field.type);
        }
      }
      expect(representedTypes, unorderedEquals(ConfigFieldType.values));
    });

    test('TI04 record format is complete and byte-wise sorted', () {
      expect(records.map((record) => record.key), orderedEquals(records.map((record) => record.key).toList()..sort()));
      for (final record in records) {
        expect(record.lines, isNotEmpty, reason: record.key);
        for (final line in record.lines) {
          expect(
            line,
            anyOf('  (none)', startsWith('  THREW: '), startsWith('  [advisory] '), startsWith('  [blocking] ')),
            reason: record.key,
          );
        }
      }
      expect(report.endsWith('\n'), isTrue);
    });

    test('TI05 comparison and portability checks fail on in-memory mutations', () {
      final committed = goldenFile.readAsStringSync();
      final mutated = committed.replaceFirst('=== ', '==== ');
      expect(_firstDifference(committed, mutated), contains('line 1'));

      List<String> failures(String value, {Map<String, String> environment = const {}}) => _portabilityFailures(
        value,
        repoRoot,
        environment: environment,
        relevantEnvironmentKeys: corpusEnvironmentKeys,
      );

      expect(failures('warning: /private/tmp/config.yaml\n'), ['absolute filesystem path']);
      expect(failures('warning: $_syntheticConfigPath\n'), ['synthetic config path', 'absolute filesystem path']);
      expect(failures('warning: ${_pinnedEnvironment['HOME']}\n'), ['pinned HOME', 'absolute filesystem path']);

      const visualKey = 'dev/testing/profiles/visual/data/dartclaw.yaml#corpus';
      for (final executable in const ['gowa', 'signal-cli']) {
        final visualExecutableMutant = _mutateCanaryLine(
          committed,
          visualKey,
          '  [blocking] Executable /nonexistent/dartclaw-visual/$executable is unavailable',
        );
        expect(failures(visualExecutableMutant), ['absolute filesystem path'], reason: executable);
      }
      expect(failures('warning: /opt/dartclaw/bin/signal-cli\n'), ['absolute filesystem path']);
      expect(failures('warning: /\n'), ['absolute filesystem path']);
      expect(
        failures(
          r'warning: C:\DartClaw\bin\signal-cli.exe'
          '\n',
        ),
        ['absolute filesystem path'],
      );
      expect(failures('warning: C:/DartClaw/bin/signal-cli.exe\n'), ['absolute filesystem path']);
      expect(
        failures(
          r'warning: \\server\dartclaw\signal-cli.exe'
          '\n',
        ),
        ['absolute filesystem path'],
      );
      expect(failures('warning: ./nonexistent/dartclaw-visual/gowa\n'), isEmpty);
      expect(failures('warning: https://example.com/nonexistent/dartclaw-visual/gowa\n'), isEmpty);

      expect(
        corpusEnvironmentKeys,
        unorderedEquals({
          'ANTHROPIC_API_KEY',
          'CODEX_API_KEY',
          'DARTCLAW_TOKEN',
          'GITHUB_TOKEN',
          'GOOGLE_CHAT_SERVICE_ACCOUNT',
          'HOME',
        }),
      );
      for (final key in corpusEnvironmentKeys) {
        final hostValue = 'real-process-value-for-$key';
        expect(failures('warning: $hostValue\n', environment: {key: hostValue}), [
          'real process environment value: $key',
        ], reason: key);
      }
    });
  });
}

Future<Directory> _resolveRepoRoot() async {
  final libraryUri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw/dartclaw.dart'));
  if (libraryUri == null) throw StateError('Could not resolve the dartclaw package root.');
  final root = Directory.fromUri(libraryUri.resolve('../../../'));
  if (!File('${root.path}/pubspec.yaml').existsSync()) {
    throw StateError('Resolved repository root does not contain pubspec.yaml: ${root.path}');
  }
  return root;
}

Set<String> _corpusEnvironmentKeys(Directory repoRoot) => {
  for (final relativePath in _corpusPaths) ...envReferences(File('${repoRoot.path}/$relativePath').readAsStringSync()),
};

Future<List<_CaseRecord>> _generateRecords(Directory repoRoot) async {
  final cases = <_Case>[
    for (final relativePath in _corpusPaths)
      _Case('$relativePath#corpus', File('${repoRoot.path}/$relativePath').readAsStringSync()),
    ..._allCases(),
  ]..sort((a, b) => a.key.compareTo(b.key));

  return [for (final configCase in cases) _record(configCase)];
}

List<_Case> _allCases() {
  final cases = <String, _Case>{};
  void add(String path, String arm, Object? value) {
    final key = '$path#$arm';
    if (cases.containsKey(key)) throw StateError('Duplicate generated case: $key');
    cases[key] = _Case(key, _yamlForPath(path, value));
  }

  for (final field in ConfigMeta.fields.values) {
    switch (field.type) {
      case ConfigFieldType.int_:
        add(field.yamlPath, 'type-string', 'not-a-number');
        add(field.yamlPath, 'type-nonstring', true);
      case ConfigFieldType.double_:
        add(field.yamlPath, 'type-nonnumber', true);
      case ConfigFieldType.string:
        add(field.yamlPath, 'type-nonstring', 1);
      case ConfigFieldType.bool_:
        add(field.yamlPath, 'type-nonbool', 'yes');
      case ConfigFieldType.enum_:
        add(field.yamlPath, 'type-nonstring', 1);
        add(field.yamlPath, 'non-member', '__dartclaw_not_a_member__');
      case ConfigFieldType.stringList:
        add(field.yamlPath, 'type-nonlist', 1);
      case ConfigFieldType.objectList || ConfigFieldType.objectMap:
        add(field.yamlPath, 'type-nonmap', 1);
    }
    if (field.min case final min?) add(field.yamlPath, 'below-min', min - 1);
    if (field.max case final max?) add(field.yamlPath, 'above-max', max + 1);
    if (field.allowedValues != null && field.type != ConfigFieldType.enum_) {
      add(field.yamlPath, 'non-member', '__dartclaw_not_a_member__');
    }

    final segments = field.yamlPath.split('.');
    for (var length = 1; length < segments.length; length++) {
      final prefix = segments.take(length).join('.');
      cases.putIfAbsent('$prefix#scalar', () => _Case('$prefix#scalar', _yamlForPath(prefix, 1)));
    }
  }

  cases['github#enabled-without-secret'] = const _Case('github#enabled-without-secret', '{"github":{"enabled":true}}');
  return cases.values.toList()..sort((a, b) => a.key.compareTo(b.key));
}

List<String> _expectedMatrixKeys() {
  final keys = <String>{};
  for (final field in ConfigMeta.fields.values) {
    final arms = switch (field.type) {
      ConfigFieldType.int_ => {'type-string', 'type-nonstring'},
      ConfigFieldType.double_ => {'type-nonnumber'},
      ConfigFieldType.string => {'type-nonstring'},
      ConfigFieldType.bool_ => {'type-nonbool'},
      ConfigFieldType.enum_ => {'type-nonstring', 'non-member'},
      ConfigFieldType.stringList => {'type-nonlist'},
      ConfigFieldType.objectList || ConfigFieldType.objectMap => {'type-nonmap'},
    };
    for (final arm in arms) {
      keys.add('${field.yamlPath}#$arm');
    }
    if (field.min != null) keys.add('${field.yamlPath}#below-min');
    if (field.max != null) keys.add('${field.yamlPath}#above-max');
    if (field.allowedValues != null) keys.add('${field.yamlPath}#non-member');

    final segments = field.yamlPath.split('.');
    for (var length = 1; length < segments.length; length++) {
      keys.add('${segments.take(length).join('.')}#scalar');
    }
  }
  keys.add('github#enabled-without-secret');
  return keys.toList()..sort();
}

String _yamlForPath(String path, Object? value) {
  Object? nested = value;
  for (final segment in path.split('.').reversed) {
    nested = <String, Object?>{segment: nested};
  }
  return jsonEncode(nested);
}

_CaseRecord _record(_Case configCase) {
  final extensionError = _githubExtensionError(configCase.document);
  try {
    final config = loadDartclawConfig(
      configPath: _syntheticConfigPath,
      fileReader: (_) => configCase.document,
      env: _pinnedEnvironment,
    );
    final blocking = [...config.reloadBlockingWarnings];
    final lines = <String>[];
    for (final warning in config.warnings) {
      final blockingIndex = blocking.indexOf(warning);
      final classification = blockingIndex < 0 ? 'advisory' : 'blocking';
      if (blockingIndex >= 0) blocking.removeAt(blockingIndex);
      lines.add('  [$classification] ${_redactVmError(warning, extensionError)}');
    }
    if (lines.isEmpty) lines.add('  (none)');
    return _CaseRecord(configCase.key, lines);
  } on FormatException catch (error) {
    return _CaseRecord(configCase.key, ['  THREW: ${error.message}']);
  }
}

Object? _githubExtensionError(String document) {
  Object? decoded;
  try {
    decoded = jsonDecode(document);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['github'] is! Map) return null;

  try {
    final github = Map<String, dynamic>.from(decoded['github'] as Map);
    parseGitHubWebhookConfig(github, <String>[]);
    return null;
  } catch (error) {
    return error;
  }
}

String _redactVmError(String warning, Object? error) {
  const prefix = 'Error parsing extension "github": ';
  const suffix = ' — storing as raw data';
  if (!warning.startsWith(prefix) || !warning.endsWith(suffix)) return warning;
  if (error == null) return warning;
  return '$prefix${error.runtimeType}$suffix';
}

String _renderReport(List<_CaseRecord> records) {
  final buffer = StringBuffer();
  for (final record in records) {
    buffer.writeln('=== ${record.key} ===');
    for (final line in record.lines) {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}

String? _firstDifference(String expected, String actual) {
  if (expected == actual) return null;
  final expectedLines = const LineSplitter().convert(expected);
  final actualLines = const LineSplitter().convert(actual);
  final length = expectedLines.length > actualLines.length ? expectedLines.length : actualLines.length;
  for (var index = 0; index < length; index++) {
    final expectedLine = index < expectedLines.length ? expectedLines[index] : '<EOF>';
    final actualLine = index < actualLines.length ? actualLines[index] : '<EOF>';
    if (expectedLine != actualLine) {
      return 'Golden differs at line ${index + 1}:\nexpected: $expectedLine\n  actual: $actualLine';
    }
  }
  return 'Golden differs in trailing bytes.';
}

List<String> _portabilityFailures(
  String value,
  Directory repoRoot, {
  required Map<String, String> environment,
  required Set<String> relevantEnvironmentKeys,
}) {
  final failures = <String>[];
  if (value.contains(_syntheticConfigPath)) failures.add('synthetic config path');
  if (value.contains(_pinnedEnvironment['HOME']!)) failures.add('pinned HOME');
  if (value.contains(repoRoot.path)) failures.add('repository checkout path');

  for (final key in relevantEnvironmentKeys) {
    final environmentValue = environment[key];
    if (environmentValue != null && environmentValue.isNotEmpty && value.contains(environmentValue)) {
      failures.add('real process environment value: $key');
    }
  }
  final pathCandidates = RegExp(
    r'''(?<![A-Za-z0-9+:/.])\/[^\s"'<>]*|(?<![A-Za-z0-9])[A-Za-z]:[\\\/][^\s"'<>]*|(?<![\\])\\\\[^\s"'<>]+''',
  ).allMatches(value).map((match) => match.group(0)!);
  if (pathCandidates.any((candidate) => p.posix.isAbsolute(candidate) || p.windows.isAbsolute(candidate))) {
    failures.add('absolute filesystem path');
  }
  if (value.contains("type '") && value.contains('is not a subtype')) failures.add('VM-owned TypeError payload');
  return failures;
}

List<String> _canaryFailures(String golden) {
  final failures = <String>[];
  for (final entry in _expectedCanaryLines.entries) {
    final block = _blockForKey(golden, entry.key);
    final expectedBlock = '=== ${entry.key} ===\n${entry.value}\n';
    if (block != expectedBlock) failures.add(entry.key);
  }
  return failures;
}

String _mutateCanaryLine(String report, String key, String replacement) {
  final marker = '=== $key ===\n';
  final markerStart = report.indexOf(marker);
  if (markerStart < 0) throw StateError('Missing canary record: $key');
  final lineStart = markerStart + marker.length;
  final lineEnd = report.indexOf('\n', lineStart);
  if (lineEnd < 0) throw StateError('Unterminated canary record: $key');
  return report.replaceRange(lineStart, lineEnd, replacement);
}

String? _blockForKey(String report, String key) {
  final marker = '=== $key ===\n';
  final start = report.indexOf(marker);
  if (start < 0) return null;
  final next = report.indexOf('=== ', start + marker.length);
  return report.substring(start, next < 0 ? report.length : next);
}

final class _Case {
  final String key;
  final String document;

  const new(this.key, this.document);
}

final class _CaseRecord {
  final String key;
  final List<String> lines;

  const new(this.key, this.lines);
}
