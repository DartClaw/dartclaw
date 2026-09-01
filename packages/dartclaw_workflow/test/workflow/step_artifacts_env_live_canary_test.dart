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

  // The Claude sibling, added 2026-08-28 when the Claude workflow lane was
  // found unable to write any file and no shipped test covered that lane at
  // all — this canary was Codex-only. Codex cannot stand in: the two providers
  // reach their permission decision by different means.
  //
  // It must force the **Write** tool, and it must make the shell fallback
  // impossible rather than merely forbid it in the prompt. Asking an agent not
  // to use Bash is not a control: on 2026-08-28 a live review step was refused
  // its `Write`, ran `cat > "$DARTCLAW_STEP_ARTIFACTS_DIR/review-report.md"`
  // instead, and the step passed with the rule dead. `Bash` in
  // `disallowedTools` is what makes "the file exists" mean "the Write tool
  // worked".
  //
  // Known limitation, recorded rather than iterated on: in this test's
  // temp-directory cwd the CLI honours `--dangerously-skip-permissions`, so the
  // write never reaches a rule check and the canary passes whichever rule form
  // is emitted. In a production step's worktree cwd the same spawn's skip is
  // nullified by `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` and the rules do decide —
  // captured from the live spawn's own argv 2026-08-28. This canary therefore
  // proves the spawn reaches the CLI and can write outside its cwd; the rule
  // form itself is pinned by `claude_settings_builder_test.dart` and by an
  // operator workflow run.
  //
  // It spawns with the step's declared canonical tools so the assertion is
  // about the rules `allowRulesForCanonicalTools` derives, not about a
  // permission-mode posture that would pass whatever those rules said. The
  // harness cwd is deliberately *not* the turn's directory: rules are derived
  // only once a spawn has an explicit execution directory, which the harness
  // establishes by restarting into it. A canary whose cwd already equals the
  // turn directory never restarts, ships `{"permissions":{"allow":[]}}`, and
  // passes on the `dontAsk` posture alone — verified from the spawn's own argv
  // 2026-08-28.
  test('a guarded-posture claude step can write into \$DARTCLAW_STEP_ARTIFACTS_DIR', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude CLI installed');
      return;
    }

    // Outside the step cwd on purpose. In production the step artifacts dir
    // lives under the data dir while the step's cwd is its worktree, and it is
    // exactly that gap the CLI's own permission layer refuses to cross when it
    // is prompting. An artifacts dir nested under the cwd proves nothing.
    final outsideCwd = Directory.systemTemp.createTempSync('dartclaw_step_artifacts_outside_');
    addTearDown(() {
      if (outsideCwd.existsSync()) outsideCwd.deleteSync(recursive: true);
    });
    final stepArtifactsDir = p.join(outsideCwd.path, 'runtime-artifacts', 'steps', 'review');
    final reportPath = p.join(stepArtifactsDir, 'report.md');
    final preExecutionCwd = Directory.systemTemp.createTempSync('dartclaw_pre_execution_cwd_');
    addTearDown(() {
      if (preExecutionCwd.existsSync()) preExecutionCwd.deleteSync(recursive: true);
    });
    expect(Directory(stepArtifactsDir).existsSync(), isFalse, reason: 'precondition: dir must not pre-exist');

    final inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
      // What `provider_resolution.dart` puts on every host claude spawn. It is
      // present on purpose and the canary is worthless without it: the harness
      // must clear it for this posture, or the CLI forces `--permission-mode
      // default` and refuses the Write below.
      'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB': '1',
      'DARTCLAW_STEP_ARTIFACTS_DIR': stepArtifactsDir,
    };
    final harness = HarnessFactory().create(
      'claude',
      HarnessFactoryConfig(
        cwd: preExecutionCwd.path,
        executable: 'claude',
        turnTimeout: const Duration(minutes: 3),
        // No permissionMode, because no production code sets one — it comes
        // only from operator `providers.claude` config, and the built-in
        // workflows ship none. The spawn therefore carries
        // `--dangerously-skip-permissions`, the scrub above makes the CLI
        // ignore it and fall back to `default`, and the derived rules are what
        // decide. Passing `dontAsk` here instead makes the write succeed
        // whether the rules are alive or dead — checked both ways 2026-08-28.
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
        messages: const [
          {
            'role': 'user',
            'content':
                'Use the **Write** tool to create the file \$DARTCLAW_STEP_ARTIFACTS_DIR/report.md '
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
          'Expected the derived allow rules to grant the Write tool for $reportPath. Bash is disallowed, '
          'so no shell fallback can have produced this file: an absent file means the rules the spawn '
          'carried do not grant writes to a path outside its cwd. Response: $response',
    );
    expect(File(reportPath).readAsStringSync(), 'canary');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
