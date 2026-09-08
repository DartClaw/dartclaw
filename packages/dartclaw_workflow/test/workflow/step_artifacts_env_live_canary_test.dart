@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show DeltaEvent, HarnessFactory, HarnessFactoryConfig, HarnessLaunchOptions;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

/// Env-export mechanism-fidelity canary (fast).
///
/// The host-side transform is fully covered by unit/integration tests
/// (`workflow_task_factory_test.dart`, `task_executor_guarded_workflow_test.dart`).
/// The one link those cannot observe is provider-internal: does the CLI export
/// the configured environment into the shell subprocess it spawns for the agent's own
/// tool call, so `$DARTCLAW_STEP_ARTIFACTS_DIR` expands? This canary proves
/// exactly that with a single trivial turn (mkdir + echo of the var) instead of
/// a full review workflow, so it runs in seconds against a live provider.
///
/// Run explicitly: `dart test --run-skipped -t integration
/// packages/dartclaw_workflow/test/workflow/step_artifacts_env_live_canary_test.dart`.
void main() {
  late bool codexReady;
  late bool claudeReady;
  late Directory tempDir;

  setUpAll(() async {
    codexReady = await codexAvailable();
    claudeReady = await claudeAvailable();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_step_artifacts_env_canary_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('the review agent shell resolves \$DARTCLAW_STEP_ARTIFACTS_DIR from the spawn env', () async {
    if (!codexReady) {
      markTestSkipped('codex binary not available – run with Codex CLI installed');
      return;
    }

    // A path that does not yet exist; only a real shell expansion of the
    // exported var can create it at exactly this absolute location (an unset
    // var would `mkdir -p ""` → nothing created here).
    final stepArtifactsDir = p.join(tempDir.path, 'runtime-artifacts', 'steps', 'review');
    expect(Directory(stepArtifactsDir).existsSync(), isFalse, reason: 'precondition: dir must not pre-exist');

    final inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'CODEX_HOME'])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
      'DARTCLAW_STEP_ARTIFACTS_DIR': stepArtifactsDir,
    };
    final harness = HarnessFactory().create(
      'codex',
      HarnessFactoryConfig(
        cwd: tempDir.path,
        executable: 'codex',
        turnTimeout: const Duration(minutes: 2),
        providerOptions: const {'sandbox': 'danger-full-access', 'approval': 'never'},
        environment: inheritedEnv,
      ),
    );
    final response = StringBuffer();
    final eventSubscription = harness.events
        .where((event) => event is DeltaEvent)
        .cast<DeltaEvent>()
        .listen((event) => response.write(event.text));
    try {
      await harness.start();
      await harness.turn(
        sessionId: 'step-artifacts-env-canary',
        messages: const [
          {
            'role': 'user',
            'content':
                'Run exactly this one shell command, then stop and report its output:\n'
                '  mkdir -p "\$DARTCLAW_STEP_ARTIFACTS_DIR" && echo "\$DARTCLAW_STEP_ARTIFACTS_DIR"\n'
                'Do not create any other directory.',
          },
        ],
        systemPrompt: '',
        directory: tempDir.path,
      );
    } finally {
      await eventSubscription.cancel();
      await harness.stop();
      await harness.dispose();
    }

    expect(
      Directory(stepArtifactsDir).existsSync(),
      isTrue,
      reason:
          'Expected the agent shell to expand \$DARTCLAW_STEP_ARTIFACTS_DIR to $stepArtifactsDir '
          '(proving the var was exported, not just present in prompt text). '
          'Response: $response',
    );
    expect(response.toString(), contains(stepArtifactsDir));
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Deny Bash so an outside-cwd file cannot be produced by a shell fallback.
  // Native permission skipping can still bypass allow-rule checks; rule
  // derivation is covered by claude_settings_builder_test.dart.
  test('a claude step can Write to its resolved artifact path outside cwd', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude CLI installed');
      return;
    }

    // Production artifacts live under the data dir, outside the step worktree.
    final outsideCwd = Directory.systemTemp.createTempSync('dartclaw_step_artifacts_outside_');
    addTearDown(() {
      if (outsideCwd.existsSync()) outsideCwd.deleteSync(recursive: true);
    });
    final stepArtifactsDir = p.join(outsideCwd.path, 'runtime-artifacts', 'steps', 'review');
    final reportPath = p.join(stepArtifactsDir, 'report.md');
    // A different initial cwd exercises the harness restart into the turn directory.
    final preExecutionCwd = Directory.systemTemp.createTempSync('dartclaw_pre_execution_cwd_');
    addTearDown(() {
      if (preExecutionCwd.existsSync()) preExecutionCwd.deleteSync(recursive: true);
    });
    expect(Directory(stepArtifactsDir).existsSync(), isFalse, reason: 'precondition: dir must not pre-exist');

    final inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
      // Match the host workflow spawn environment.
      'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB': '1',
      'DARTCLAW_STEP_ARTIFACTS_DIR': stepArtifactsDir,
    };
    final harness = HarnessFactory().create(
      'claude',
      HarnessFactoryConfig(
        cwd: preExecutionCwd.path,
        executable: 'claude',
        turnTimeout: const Duration(minutes: 3),
        declaredCanonicalTools: const ['file_read', 'file_write'],
        declaredWritableRoots: [stepArtifactsDir],
        harnessConfig: const HarnessLaunchOptions(disallowedTools: ['Bash']),
        environment: inheritedEnv,
      ),
    );
    final response = StringBuffer();
    final eventSubscription = harness.events
        .where((event) => event is DeltaEvent)
        .cast<DeltaEvent>()
        .listen((event) => response.write(event.text));
    try {
      await harness.start();
      await harness.turn(
        sessionId: 'step-artifacts-write-canary',
        messages: [
          {
            'role': 'user',
            'content':
                'Use the **Write** tool to create the file $reportPath '
                'with the exact contents: canary\n'
                'Then report whether the write succeeded.',
          },
        ],
        systemPrompt: '',
        directory: tempDir.path,
      );
    } finally {
      await eventSubscription.cancel();
      await harness.stop();
      await harness.dispose();
    }

    expect(
      File(reportPath).existsSync(),
      isTrue,
      reason:
          'Expected Write to create $reportPath outside the turn directory ${tempDir.path}. '
          'Bash is disallowed, so no shell fallback can produce the file. Response: $response',
    );
    // Write may append a newline; this canary checks the target and contents, not the trailing delimiter.
    expect(File(reportPath).readAsStringSync().trim(), 'canary');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
