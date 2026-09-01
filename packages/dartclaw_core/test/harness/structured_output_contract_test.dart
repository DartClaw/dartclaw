import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/harness/claude_protocol.dart' show claudeStructuredOutputRetriesExhaustedSubtype;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

const _schema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'verdict': {'type': 'string'},
  },
  'required': ['verdict'],
  'additionalProperties': false,
};

const _otherSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'score': {'type': 'integer'},
  },
  'required': ['score'],
  'additionalProperties': false,
};

const _payload = <String, dynamic>{'verdict': 'approved'};

const _message = [
  {'role': 'user', 'content': 'classify this'},
];

void main() {
  group('structured-output capability contract', () {
    test('the conformance suite covers every production AgentHarness implementation', () async {
      // Enumerated from source rather than listed by hand, so a fourth harness
      // cannot ship without a fixture here.
      expect(await _discoverProductionHarnesses(), _harnessProbes.keys.toSet());
    });

    _harnessProbes.forEach((harnessName, probe) {
      test('$harnessName: declared structured-output support matches observed behaviour', probe);
    });
  });

  group('ClaudeCodeHarness structured output', () {
    test('a schema-bearing turn puts the schema on the spawn arguments and returns the enforced payload', () async {
      final spawns = <List<String>>[];
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          result: const {'structured_output': _payload},
          onSpawn: (spawn) => spawns.add(spawn.args),
        ),
      );
      addTearDown(harness.dispose);
      await harness.start();

      final result = await harness.turn(
        sessionId: 'schema-session',
        messages: _message,
        systemPrompt: '',
        outputSchema: _schema,
      );

      expect(_schemaArgument(spawns.last), jsonEncode(_schema));
      expect(result.structuredOutput, _payload);
      expect(result.isError, isFalse);
    });

    test('changing the schema between turns restarts once and an unchanged schema does not restart', () async {
      final driver = _ClaudeProcessDriver();
      final harness = buildClaudeHarness(processFactory: driver.factory);
      addTearDown(harness.dispose);
      await harness.start();
      expect(driver.spawns.length, 1);

      await driver.runTurn(harness, outputSchema: _schema);
      expect(driver.spawns.length, 2, reason: 'the first schema is a process-level change');

      await driver.runTurn(harness, outputSchema: _schema);
      expect(driver.spawns.length, 2, reason: 'an unchanged schema keeps the running process');

      await driver.runTurn(harness, outputSchema: _otherSchema);
      expect(driver.spawns.length, 3, reason: 'a changed schema requires the process to be respawned');
      expect(_schemaArgument(driver.spawns.last), jsonEncode(_otherSchema));
    });

    test('structured-output retry exhaustion fails the turn instead of returning an empty success', () async {
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          result: const {'subtype': claudeStructuredOutputRetriesExhaustedSubtype, 'is_error': false},
        ),
      );
      addTearDown(harness.dispose);
      await harness.start();

      final result = await harness.turn(
        sessionId: 'exhausted',
        messages: _message,
        systemPrompt: '',
        outputSchema: _schema,
      );

      expect(result.isError, isTrue);
      expect(result.error, contains(claudeStructuredOutputRetriesExhaustedSubtype));
      expect(result.structuredOutput, isNull);
    });

    test('retry exhaustion keeps the provider validation detail alongside the subtype', () async {
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(
          result: const {
            'subtype': claudeStructuredOutputRetriesExhaustedSubtype,
            'is_error': true,
            'result': "output did not match schema: required property 'verdict' missing",
          },
        ),
      );
      addTearDown(harness.dispose);
      await harness.start();

      final result = await harness.turn(
        sessionId: 'exhausted-detail',
        messages: _message,
        systemPrompt: '',
        outputSchema: _schema,
      );

      expect(result.isError, isTrue);
      expect(result.error, contains(claudeStructuredOutputRetriesExhaustedSubtype));
      expect(result.error, contains("required property 'verdict' missing"));
    });

    test('a schema-free turn spawns without the schema flag and reports no structured output', () async {
      final spawns = <List<String>>[];
      final harness = buildClaudeHarness(
        processFactory: resultEmittingFactory(onSpawn: (spawn) => spawns.add(spawn.args)),
      );
      addTearDown(harness.dispose);
      await harness.start();

      final result = await harness.turn(sessionId: 'plain', messages: _message, systemPrompt: '');

      expect(spawns.every((args) => !args.contains('--json-schema')), isTrue);
      expect(result.structuredOutput, isNull);
    });
  });

  group('CodexHarness structured output', () {
    test('a schema-bearing turn is refused before any turn/start reaches the app server', () async {
      final process = FakeCodexProcess(completeExitOnKill: true);
      final harness = _codexHarness(process);
      addTearDown(harness.dispose);
      await startHarness(harness, process);

      await expectLater(
        harness.turn(sessionId: 's', messages: _message, systemPrompt: '', outputSchema: _schema),
        throwsA(
          isA<UnsupportedHarnessCapabilityException>()
              .having((e) => e.provider, 'provider', 'CodexHarness')
              .having((e) => e.capability, 'capability', AgentHarness.structuredOutputCapability),
        ),
      );

      expect(process.sentMessages.where((m) => m['method'] == 'turn/start'), isEmpty);
    });

    test('a schema-free turn/start carries no schema key', () async {
      final process = FakeCodexProcess(completeExitOnKill: true);
      final harness = _codexHarness(process);
      addTearDown(harness.dispose);
      await startHarness(harness, process);

      unawaited(
        harness.turn(sessionId: 's', messages: _message, systemPrompt: '').catchError((_) => const TurnResult()),
      );
      await respondToLatestThreadStart(process);
      await waitForSentMessage(process, 'turn/start');

      final params =
          process.sentMessages.lastWhere((m) => m['method'] == 'turn/start')['params'] as Map<String, dynamic>;
      expect(params.keys, isNot(contains('outputSchema')));
      expect(params.keys, isNot(contains('output_schema')));
    });
  });

  group('FakeAgentHarness structured output', () {
    test('the unsupported posture refuses a schema-bearing turn', () async {
      final fake = FakeAgentHarness();
      expect(fake.supportsStructuredOutput, isFalse);

      await expectLater(
        fake.turn(sessionId: 's', messages: _message, systemPrompt: '', outputSchema: _schema),
        throwsA(isA<UnsupportedHarnessCapabilityException>()),
      );
      expect(fake.turnCallCount, 0);
    });

    test('the supported posture records the schema and returns the configured payload', () async {
      final fake = FakeAgentHarness(supportsStructuredOutput: true)..structuredOutputResponse = _payload;

      final turnFuture = fake.turn(sessionId: 's', messages: _message, systemPrompt: '', outputSchema: _schema);
      await fake.turnInvoked;
      fake.completeSuccess();

      expect(fake.lastOutputSchema, _schema);
      expect((await turnFuture).structuredOutput, _payload);
    });
  });
}

/// Both directions of the capability contract for one production harness:
/// declared support must put the schema on the wire and return a payload,
/// declared non-support must refuse before the provider is touched.
final Map<String, Future<void> Function()> _harnessProbes = {
  'ClaudeCodeHarness': () async {
    final spawns = <List<String>>[];
    final harness = buildClaudeHarness(
      processFactory: resultEmittingFactory(
        result: const {'structured_output': _payload},
        onSpawn: (spawn) => spawns.add(spawn.args),
      ),
    );
    addTearDown(harness.dispose);
    await harness.start();

    if (harness.supportsStructuredOutput) {
      final result = await harness.turn(sessionId: 's', messages: _message, systemPrompt: '', outputSchema: _schema);
      expect(_schemaArgument(spawns.last), jsonEncode(_schema));
      expect(result.structuredOutput, isNotNull);
    } else {
      await _expectRefusal(harness, 'ClaudeCodeHarness');
      expect(spawns.every((args) => !args.contains('--json-schema')), isTrue);
    }
  },
  'CodexHarness': () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = _codexHarness(process);
    addTearDown(harness.dispose);
    await startHarness(harness, process);

    if (harness.supportsStructuredOutput) {
      final turnFuture = harness.turn(sessionId: 's', messages: _message, systemPrompt: '', outputSchema: _schema);
      await respondToLatestThreadStart(process);
      await waitForSentMessage(process, 'turn/start');
      final params =
          process.sentMessages.lastWhere((m) => m['method'] == 'turn/start')['params'] as Map<String, dynamic>;
      expect(params['outputSchema'], _schema);
      process.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      expect(
        (await turnFuture).structuredOutput,
        isNotNull,
        reason: 'declared support must return the enforced payload, not merely forward the key',
      );
    } else {
      await _expectRefusal(harness, 'CodexHarness');
      expect(process.sentMessages.where((m) => m['method'] == 'turn/start'), isEmpty);
    }
  },
};

Future<void> _expectRefusal(AgentHarness harness, String provider) async {
  await expectLater(
    harness.turn(sessionId: 's', messages: _message, systemPrompt: '', outputSchema: _schema),
    throwsA(
      isA<UnsupportedHarnessCapabilityException>()
          .having((e) => e.provider, 'provider', provider)
          .having((e) => e.capability, 'capability', AgentHarness.structuredOutputCapability),
    ),
  );
}

String? _schemaArgument(List<String> args) {
  final index = args.indexOf('--json-schema');
  return index < 0 ? null : args[index + 1];
}

CodexHarness _codexHarness(FakeCodexProcess process) => CodexHarness(
  cwd: '/tmp',
  executable: 'codex',
  processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
  commandProbe: defaultCommandProbe,
  delayFactory: noOpDelay,
  environment: const {'OPENAI_API_KEY': 'sk-test-key'},
  killGracePeriod: Duration.zero,
);

/// Class names of every concrete `AgentHarness` implementation shipped in the
/// harness source directory, found by declaration rather than by a hand-kept
/// list. Covers subdirectories and subclasses of any `*Harness`.
///
/// The `implements` clause is parsed rather than substring-matched: a substring
/// test passes only when `AgentHarness` leads the list, and misses a prefixed
/// `core.AgentHarness`. Harness *placement* under `lib/src/harness/` is a
/// convention, not a gate - no fitness function or `arch_check` rule enforces
/// it - so a harness written elsewhere escapes this suite.
Future<Set<String>> _discoverProductionHarnesses() async {
  final directory = await _harnessSourceDirectory();
  final declaration = RegExp(
    r'^(abstract\s+)?(?:final\s+|base\s+|sealed\s+|mixin\s+|interface\s+)*class\s+(\w+)\b([^{]*)\{',
    multiLine: true,
  );
  final extendsHarness = RegExp(r'\bextends\s+\w*Harness\b');
  final names = <String>{};
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    for (final match in declaration.allMatches(entity.readAsStringSync())) {
      if (match.group(1) != null) continue;
      final header = match.group(3)!;
      if (extendsHarness.hasMatch(header) || _implementsAgentHarness(header)) {
        names.add(match.group(2)!);
      }
    }
  }
  expect(names, isNotEmpty, reason: 'no harness implementations found under ${directory.path}');
  return names;
}

/// Whether [header]'s `implements` clause names `AgentHarness` in any position,
/// with or without an import prefix.
bool _implementsAgentHarness(String header) {
  final clause = RegExp(r'\bimplements\s+([^{]*)').firstMatch(header);
  if (clause == null) return false;
  return clause
      .group(1)!
      .split(',')
      .map((type) => type.trim().split('<').first.split('.').last)
      .contains('AgentHarness');
}

/// Resolved through the package URI rather than the working directory, so this
/// suite adds no cwd reader to the package (`dev/tools/test_workspace.sh`).
Future<Directory> _harnessSourceDirectory() async {
  final barrel = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_core/dartclaw_core.dart'));
  if (barrel == null) fail('Could not resolve package:dartclaw_core');
  return Directory(barrel.resolve('src/harness/').toFilePath());
}

/// Claude process factory that keeps the newest spawned fake reachable and
/// answers one turn at a time, so a test can drive several turns across the
/// restarts a changed spawn argument forces.
final class _ClaudeProcessDriver {
  final List<List<String>> spawns = [];
  CapturingFakeProcess? _current;
  int _answered = 0;

  ProcessFactory get factory => (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
    spawns.add(args);
    final fake = makeCapturingClaudeProcess();
    _current = fake;
    _answered = 0;
    scheduleMicrotask(() => fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
    return fake;
  };

  Future<TurnResult> runTurn(ClaudeCodeHarness harness, {Map<String, dynamic>? outputSchema}) async {
    final turnFuture = harness.turn(
      sessionId: 'driver-session',
      messages: _message,
      systemPrompt: '',
      outputSchema: outputSchema,
    );
    for (var attempt = 0; attempt < 200; attempt++) {
      final fake = _current;
      if (fake != null && fake.capturedStdinJson.where((m) => m['type'] == 'user').length > _answered) {
        _answered++;
        fake.emitStdout(jsonEncode({'type': 'result', 'result': 'ok', 'is_error': false, 'session_id': 'driver'}));
        return turnFuture;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('No turn request reached the fake Claude process');
  }
}
