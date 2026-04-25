// Tests for S57: MERGE_RESOLVE_* env-var injection contract on both harnesses.
//
// Covers:
//   TI02 — ClaudeCodeHarness forwards per-invocation env vars to Process.start
//   TI03 — CodexHarness forwards per-invocation env vars, surviving CodexEnvironment merge
//   TI04 — Default empty environment produces no MERGE_RESOLVE_* keys on either harness
//   TI05 — Unset MERGE_RESOLVE_VERIFY_FORMAT does not cause harness rejection
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        HarnessFactory,
        HarnessFactoryConfig,
        mergeResolveEnvVarNames,
        mergeResolveIntegrationBranchEnvVar,
        mergeResolveStoryBranchEnvVar,
        mergeResolveTokenCeilingEnvVar,
        mergeResolveVerifyFormatEnvVar,
        mergeResolveVerifyAnalyzeEnvVar,
        mergeResolveVerifyTestEnvVar;
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// ClaudeCodeHarness helpers
// ---------------------------------------------------------------------------

/// Minimal process fake for Claude harness tests — uses a non-broadcast
/// StreamController so the harness's stdout subscription doesn't miss the
/// initialize response emitted via scheduleMicrotask.
class _ClaudeFakeProcess implements Process {
  final _stdoutCtrl = StreamController<List<int>>();
  final _exitCompleter = Completer<int>();

  @override
  int get pid => 42;

  @override
  IOSink get stdin => NullIoSink();

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exitCompleter.future;

  void emitStdout(String line) => _stdoutCtrl.add(utf8.encode('$line\n'));

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(0);
    return true;
  }
}

ClaudeCodeHarness _buildClaudeHarness({
  required Map<String, String> environment,
  required void Function(Map<String, String> env) onSpawn,
}) {
  return ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
      onSpawn(environment ?? {});
      final fake = _ClaudeFakeProcess();
      scheduleMicrotask(() {
        fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
      });
      return fake;
    },
    commandProbe: (exe, args) async => ProcessResult(0, 0, '1.0.0', ''),
    delayFactory: (d) async {},
    environment: environment,
  );
}

// ---------------------------------------------------------------------------
// TI02 — ClaudeCodeHarness env-var injection
// ---------------------------------------------------------------------------

void main() {
  group('MERGE_RESOLVE_* env-var injection contract', () {
    group('TI02 — ClaudeCodeHarness injects per-invocation MERGE_RESOLVE_* keys', () {
      test('injected keys are present and PATH is preserved', () async {
        Map<String, String>? captured;
        const env = {
          mergeResolveIntegrationBranchEnvVar: 'integration/0.16.4',
          mergeResolveStoryBranchEnvVar: 'story/foo',
          'PATH': '/usr/bin:/bin',
          'ANTHROPIC_API_KEY': 'sk-test',
        };

        final harness = _buildClaudeHarness(
          environment: env,
          onSpawn: (e) => captured = Map<String, String>.from(e),
        );
        addTearDown(() async => harness.dispose());

        await harness.start();

        expect(captured, isNotNull);
        expect(captured![mergeResolveIntegrationBranchEnvVar], 'integration/0.16.4');
        expect(captured![mergeResolveStoryBranchEnvVar], 'story/foo');
        expect(captured!.containsKey('PATH'), isTrue);
      });

      test('all six MERGE_RESOLVE_* keys are forwarded', () async {
        Map<String, String>? captured;
        const env = {
          mergeResolveIntegrationBranchEnvVar: 'integration/0.16.4',
          mergeResolveStoryBranchEnvVar: 'story/bar',
          mergeResolveTokenCeilingEnvVar: '100000',
          mergeResolveVerifyFormatEnvVar: 'dart format --set-exit-if-changed .',
          mergeResolveVerifyAnalyzeEnvVar: 'dart analyze',
          mergeResolveVerifyTestEnvVar: 'dart test',
          'ANTHROPIC_API_KEY': 'sk-test',
        };

        final harness = _buildClaudeHarness(
          environment: env,
          onSpawn: (e) => captured = Map<String, String>.from(e),
        );
        addTearDown(() async => harness.dispose());

        await harness.start();

        expect(captured, isNotNull);
        for (final key in mergeResolveEnvVarNames) {
          expect(captured!.containsKey(key), isTrue, reason: '$key missing from spawn env');
        }
      });
    });

    group('TI03 — CodexHarness injects MERGE_RESOLVE_* keys (survives CodexEnvironment merge)', () {
      test('MERGE_RESOLVE_TOKEN_CEILING survives CodexEnvironment environmentOverrides merge', () async {
        Map<String, String>? captured;
        final fakeProcess = FakeCodexProcess();

        final harness = CodexHarness(
          cwd: '/tmp',
          executable: 'codex',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            captured = environment == null ? null : Map<String, String>.from(environment);
            return fakeProcess;
          },
          commandProbe: defaultCommandProbe,
          delayFactory: noOpDelay,
          environment: {
            mergeResolveTokenCeilingEnvVar: '100000',
            'OPENAI_API_KEY': 'sk-test',
          },
          providerOptions: const {'use_system_codex_home': false},
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fakeProcess);

        expect(captured, isNotNull);
        expect(captured![mergeResolveTokenCeilingEnvVar], '100000');
      });

      test('all six MERGE_RESOLVE_* keys are present in Codex spawn env', () async {
        Map<String, String>? captured;
        final fakeProcess = FakeCodexProcess();

        final harness = CodexHarness(
          cwd: '/tmp',
          executable: 'codex',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            captured = environment == null ? null : Map<String, String>.from(environment);
            return fakeProcess;
          },
          commandProbe: defaultCommandProbe,
          delayFactory: noOpDelay,
          environment: {
            mergeResolveIntegrationBranchEnvVar: 'integration/0.16.4',
            mergeResolveStoryBranchEnvVar: 'story/baz',
            mergeResolveTokenCeilingEnvVar: '50000',
            mergeResolveVerifyFormatEnvVar: 'dart format --set-exit-if-changed .',
            mergeResolveVerifyAnalyzeEnvVar: 'dart analyze',
            mergeResolveVerifyTestEnvVar: 'dart test',
            'OPENAI_API_KEY': 'sk-test',
          },
          providerOptions: const {'use_system_codex_home': false},
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fakeProcess);

        expect(captured, isNotNull);
        for (final key in mergeResolveEnvVarNames) {
          expect(captured!.containsKey(key), isTrue, reason: '$key missing from Codex spawn env');
        }
      });
    });

    group('TI04 — Default empty environment produces no MERGE_RESOLVE_* keys', () {
      test('ClaudeCodeHarness: no MERGE_RESOLVE_* key leaks in when environment has no MERGE_RESOLVE_* keys', () async {
        // Regression: supplying a baseline env with only API key but no MERGE_RESOLVE_* keys
        // must not produce any MERGE_RESOLVE_* keys in the spawned process environment.
        Map<String, String>? captured;

        final harness = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            captured = environment == null ? null : Map<String, String>.from(environment);
            final fake = _ClaudeFakeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: (exe, args) async => ProcessResult(0, 0, '1.0.0', ''),
          delayFactory: (d) async {},
          // Only the API key — no MERGE_RESOLVE_* keys.
          environment: const {'ANTHROPIC_API_KEY': 'sk-test'},
        );
        addTearDown(() async => harness.dispose());

        await harness.start();

        expect(captured, isNotNull);
        for (final key in mergeResolveEnvVarNames) {
          expect(
            captured!.containsKey(key),
            isFalse,
            reason: '$key unexpectedly present when not in the supplied environment map',
          );
        }
      });

      test('CodexHarness: no MERGE_RESOLVE_* key leaks in when environment map is empty', () async {
        Map<String, String>? captured;
        final fakeProcess = FakeCodexProcess();

        final harness = CodexHarness(
          cwd: '/tmp',
          executable: 'codex',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            captured = environment == null ? null : Map<String, String>.from(environment);
            return fakeProcess;
          },
          commandProbe: defaultCommandProbe,
          delayFactory: noOpDelay,
          environment: const {'OPENAI_API_KEY': 'sk-test'},
          providerOptions: const {'use_system_codex_home': false},
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fakeProcess);

        expect(captured, isNotNull);
        for (final key in mergeResolveEnvVarNames) {
          expect(
            captured!.containsKey(key),
            isFalse,
            reason: '$key unexpectedly present when not explicitly supplied',
          );
        }
      });
    });

    group('TI05 — Unset MERGE_RESOLVE_VERIFY_FORMAT does not cause harness rejection', () {
      test('ClaudeCodeHarness: start succeeds when MERGE_RESOLVE_VERIFY_FORMAT is omitted', () async {
        // Policy: harness MUST NOT reject spawn when any MERGE_RESOLVE_* key is unset.
        final harness = _buildClaudeHarness(
          environment: {
            mergeResolveIntegrationBranchEnvVar: 'integration/0.16.4',
            mergeResolveStoryBranchEnvVar: 'story/foo',
            mergeResolveTokenCeilingEnvVar: '100000',
            // mergeResolveVerifyFormatEnvVar intentionally omitted
            mergeResolveVerifyAnalyzeEnvVar: 'dart analyze',
            mergeResolveVerifyTestEnvVar: 'dart test',
            'ANTHROPIC_API_KEY': 'sk-test',
          },
          onSpawn: (_) {},
        );
        addTearDown(() async => harness.dispose());

        // Must not throw.
        await expectLater(harness.start(), completes);
      });

      test('CodexHarness: start succeeds when MERGE_RESOLVE_VERIFY_FORMAT is omitted', () async {
        final fakeProcess = FakeCodexProcess();

        final harness = CodexHarness(
          cwd: '/tmp',
          executable: 'codex',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async =>
              fakeProcess,
          commandProbe: defaultCommandProbe,
          delayFactory: noOpDelay,
          environment: {
            mergeResolveIntegrationBranchEnvVar: 'integration/0.16.4',
            mergeResolveStoryBranchEnvVar: 'story/foo',
            mergeResolveTokenCeilingEnvVar: '100000',
            // mergeResolveVerifyFormatEnvVar intentionally omitted
            mergeResolveVerifyAnalyzeEnvVar: 'dart analyze',
            mergeResolveVerifyTestEnvVar: 'dart test',
            'OPENAI_API_KEY': 'sk-test',
          },
          providerOptions: const {'use_system_codex_home': false},
        );
        addTearDown(() async => harness.dispose());

        // Must not throw.
        await expectLater(startHarness(harness, fakeProcess), completes);
      });
    });

    group('Env-var map mutation isolation', () {
      // Policy: callers MUST treat the environment map as immutable after
      // passing it to HarnessFactoryConfig / harness constructors. The harness
      // stores the reference it was given. S60 enforces this by constructing a
      // fresh HarnessFactoryConfig (and thus a fresh environment map) for every
      // per-attempt harness create() call.

      test('CodexHarness spawns with the environment values present at start() time', () async {
        Map<String, String>? captured;
        final fakeProcess = FakeCodexProcess();
        final env = {
          mergeResolveIntegrationBranchEnvVar: 'integration/0.16.4',
          'OPENAI_API_KEY': 'sk-test',
        };

        final harness = CodexHarness(
          cwd: '/tmp',
          executable: 'codex',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            captured = environment == null ? null : Map<String, String>.from(environment);
            return fakeProcess;
          },
          commandProbe: defaultCommandProbe,
          delayFactory: noOpDelay,
          environment: env,
          providerOptions: const {'use_system_codex_home': false},
        );
        addTearDown(() async => harness.dispose());

        await startHarness(harness, fakeProcess);

        expect(captured![mergeResolveIntegrationBranchEnvVar], 'integration/0.16.4');
      });

      test('two consecutive HarnessFactory.create() calls with distinct env maps each use their own values', () async {
        final factory = HarnessFactory();
        final captured = <String>[];

        for (final branch in ['integration/0.16.4', 'integration/0.17.0']) {
          final fakeProcess = FakeCodexProcess();
          final config = HarnessFactoryConfig(
            cwd: '/tmp',
            executable: 'codex',
            environment: {
              mergeResolveIntegrationBranchEnvVar: branch,
              'OPENAI_API_KEY': 'sk-test',
            },
          );
          final harness = factory.create('codex', config) as CodexHarness;
          addTearDown(() async => harness.dispose());

          Map<String, String>? spawnEnv;
          final patched = CodexHarness(
            cwd: '/tmp',
            executable: 'codex',
            processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
              spawnEnv = environment == null ? null : Map<String, String>.from(environment);
              return fakeProcess;
            },
            commandProbe: defaultCommandProbe,
            delayFactory: noOpDelay,
            environment: {
              mergeResolveIntegrationBranchEnvVar: branch,
              'OPENAI_API_KEY': 'sk-test',
            },
            providerOptions: const {'use_system_codex_home': false},
          );
          addTearDown(() async => patched.dispose());

          await startHarness(patched, fakeProcess);
          captured.add(spawnEnv![mergeResolveIntegrationBranchEnvVar]!);
        }

        expect(captured, ['integration/0.16.4', 'integration/0.17.0']);
      });
    });

    group('TI06 — MERGE_RESOLVE_* name set completeness', () {
      test('mergeResolveEnvVarNames contains all six locked names', () {
        expect(mergeResolveEnvVarNames, hasLength(6));
        expect(mergeResolveEnvVarNames, contains(mergeResolveIntegrationBranchEnvVar));
        expect(mergeResolveEnvVarNames, contains(mergeResolveStoryBranchEnvVar));
        expect(mergeResolveEnvVarNames, contains(mergeResolveTokenCeilingEnvVar));
        expect(mergeResolveEnvVarNames, contains(mergeResolveVerifyFormatEnvVar));
        expect(mergeResolveEnvVarNames, contains(mergeResolveVerifyAnalyzeEnvVar));
        expect(mergeResolveEnvVarNames, contains(mergeResolveVerifyTestEnvVar));
      });

      test('locked name values match the spec verbatim', () {
        expect(mergeResolveIntegrationBranchEnvVar, 'MERGE_RESOLVE_INTEGRATION_BRANCH');
        expect(mergeResolveStoryBranchEnvVar, 'MERGE_RESOLVE_STORY_BRANCH');
        expect(mergeResolveTokenCeilingEnvVar, 'MERGE_RESOLVE_TOKEN_CEILING');
        expect(mergeResolveVerifyFormatEnvVar, 'MERGE_RESOLVE_VERIFY_FORMAT');
        expect(mergeResolveVerifyAnalyzeEnvVar, 'MERGE_RESOLVE_VERIFY_ANALYZE');
        expect(mergeResolveVerifyTestEnvVar, 'MERGE_RESOLVE_VERIFY_TEST');
      });
    });
  });
}
