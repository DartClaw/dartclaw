@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowCliProviderConfig, WorkflowCliRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

/// Env-export mechanism-fidelity canary (fast).
///
/// The host-side transform is fully covered by unit/integration tests
/// (`workflow_task_factory_test.dart`, `task_executor_workflow_oneshot_test.dart`).
/// The one link those cannot observe is provider-internal: does the CLI export
/// `extraEnvironment` into the shell subprocess it spawns for the agent's own
/// tool call, so `$DARTCLAW_STEP_ARTIFACTS_DIR` expands? This canary proves
/// exactly that with a single trivial turn (mkdir + echo of the var) instead of
/// a full review workflow, so it runs in seconds against a live provider.
///
/// Run explicitly: `dart test --run-skipped -t integration
/// packages/dartclaw_workflow/test/workflow/step_artifacts_env_live_canary_test.dart`.
void main() {
  late bool codexReady;
  late WorkflowCliRunner runner;
  late Directory tempDir;

  setUpAll(() async {
    codexReady = await codexAvailable();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_step_artifacts_env_canary_');
    // SafeProcess.start runs with includeParentEnvironment: false, so hand the
    // codex binary PATH/HOME explicitly (mirrors the step-isolation canary).
    final inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
    };
    runner = WorkflowCliRunner(
      providers: {
        'codex': WorkflowCliProviderConfig(
          executable: 'codex',
          options: const {'sandbox': 'danger-full-access'},
          environment: inheritedEnv,
        ),
      },
    );
  });

  tearDown(() async {
    await runner.cancelInflight();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'the review agent shell resolves \$DARTCLAW_STEP_ARTIFACTS_DIR from the spawn env',
    () async {
      if (!codexReady) {
        markTestSkipped('codex binary not available – run with Codex CLI installed');
        return;
      }

      // A path that does not yet exist; only a real shell expansion of the
      // exported var can create it at exactly this absolute location (an unset
      // var would `mkdir -p ""` → nothing created here).
      final stepArtifactsDir = p.join(tempDir.path, 'runtime-artifacts', 'steps', 'review');
      expect(Directory(stepArtifactsDir).existsSync(), isFalse, reason: 'precondition: dir must not pre-exist');

      final turnResult = await runner.executeTurn(
        provider: 'codex',
        prompt:
            'Run exactly this one shell command, then stop and report its output:\n'
            '  mkdir -p "\$DARTCLAW_STEP_ARTIFACTS_DIR" && echo "\$DARTCLAW_STEP_ARTIFACTS_DIR"\n'
            'Do not create any other directory.',
        workingDirectory: tempDir.path,
        profileId: 'default',
        stepTimeout: const Duration(minutes: 2),
        stepName: 'step-artifacts-env-canary',
        extraEnvironment: {'DARTCLAW_STEP_ARTIFACTS_DIR': stepArtifactsDir},
      );

      expect(
        Directory(stepArtifactsDir).existsSync(),
        isTrue,
        reason:
            'Expected the agent shell to expand \$DARTCLAW_STEP_ARTIFACTS_DIR to $stepArtifactsDir '
            '(proving the var was exported, not just present in prompt text). '
            'Response: ${turnResult.responseText}',
      );
      expect(turnResult.responseText, contains(stepArtifactsDir));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
