import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ClaudeCodeHarness;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  group('ClaudeCodeHarness permission optimization', () {
    test('uses --dangerously-skip-permissions when spawning claude', () async {
      final capturedArgs = await startHarnessAndCaptureArgs();

      expect(capturedArgs, contains('--dangerously-skip-permissions'));
    });

    test('does not pass --permission-prompt-tool stdio when spawning claude', () async {
      final capturedArgs = await startHarnessAndCaptureArgs();

      expect(capturedArgs, isNot(contains('--permission-prompt-tool')));
      expect(capturedArgs, isNot(contains('stdio')));
    });

    test('approval never selects bypassPermissions and disables env scrub', () async {
      ProcessSpawn? spawn;
      final process = makeCapturingClaudeProcess();
      final harness = buildClaudeHarness(
        providerOptions: const {'approval': 'never'},
        processFactory: capturingInitFactory(process: process, onSpawn: (value) => spawn = value),
      );
      addTearDown(harness.dispose);

      await harness.start();

      expect(spawn!.args, containsAllInOrder(['--permission-mode', 'bypassPermissions']));
      expect(spawn!.environment!['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '0');
    });

    test('a workflow step spawn stops inheriting the operator user settings', () async {
      // A server lane whose tool policy varies with whoever's
      // `~/.claude/settings.json` is on the host is nondeterministic by
      // construction: on 2026-08-28 a review step's Bash calls ran on the
      // developer's personal rules while its Write calls were refused.
      final capturedArgs = await startHarnessAndCaptureArgs(
        providerOptions: {'permissionMode': 'dontAsk'},
        declaredCanonicalTools: const ['shell'],
      );

      expect(capturedArgs, containsAllInOrder(['--setting-sources', 'project']));
    });

    test('a pre-execution step spawn grants nothing rather than the server cwd', () async {
      // Deriving the worktree root from the construction cwd would hand a
      // workflow step write access to the DartClaw checkout itself — observed
      // live 2026-08-28 as `Write(/Users/.../dartclaw-public-0.25/**)` on the
      // spawn that precedes the restart for execution (the rule form has since
      // been corrected to `Edit(//...)`; the over-grant is what this pins).
      ProcessSpawn? spawn;
      final harness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        declaredCanonicalTools: const ['shell', 'file_write'],
        processFactory: capturingInitFactory(onSpawn: (value) => spawn = value),
      );
      addTearDown(harness.dispose);

      await harness.start();

      final settingsIndex = spawn!.args.indexOf('--settings');
      final allow =
          ((jsonDecode(spawn!.args[settingsIndex + 1]) as Map<String, dynamic>)['permissions']
              as Map<String, dynamic>)['allow'];
      expect(allow, isEmpty, reason: 'a spawn whose execution directory is unknown may grant nothing');
      expect(jsonEncode(allow), isNot(contains('/tmp')), reason: 'the construction cwd must never become a root');
    });

    test('a spawn with no declared tools keeps inheriting user settings', () async {
      final capturedArgs = await startHarnessAndCaptureArgs(providerOptions: {'permissionMode': 'dontAsk'});

      expect(capturedArgs, isNot(contains('--setting-sources')));
    });

    group('writable-root derivation', () {
      test('an unknown execution directory contributes no root', () {
        // The construction cwd is the server's own; deriving from it granted
        // workflow steps write access to the DartClaw checkout (live 2026-08-28).
        final roots = ClaudeCodeHarness.writableRootsForSpawn(
          executionDirectory: null,
          declaredRoots: const ['/artifacts/steps/review'],
          containerManager: null,
        );
        expect(roots, ['/artifacts/steps/review']);
      });

      test('a known execution directory joins the declared roots', () {
        final roots = ClaudeCodeHarness.writableRootsForSpawn(
          executionDirectory: '/worktrees/wf-1',
          declaredRoots: const ['/artifacts/steps/review'],
          containerManager: null,
        );
        expect(roots, ['/worktrees/wf-1', '/artifacts/steps/review']);
      });

      test('container roots are translated to their container-side paths', () async {
        // Host paths would match nothing inside the container and deny every write.
        final hostRoot = await Directory.systemTemp.createTemp('dartclaw-claude-roots-mounted-');
        addTearDown(() => hostRoot.delete(recursive: true));
        final roots = ClaudeCodeHarness.writableRootsForSpawn(
          executionDirectory: hostRoot.path,
          declaredRoots: [p.join(hostRoot.path, 'artifacts')],
          containerManager: FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace'),
        );
        expect(roots, ['/workspace', '/workspace/artifacts']);
      });

      test('a root the container does not mount is refused, never dropped', () async {
        final hostRoot = await Directory.systemTemp.createTemp('dartclaw-claude-roots-unmounted-');
        addTearDown(() => hostRoot.delete(recursive: true));
        expect(
          () => ClaudeCodeHarness.writableRootsForSpawn(
            executionDirectory: hostRoot.path,
            declaredRoots: const ['/somewhere/else'],
            containerManager: FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace'),
          ),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('not mounted in the container'))),
        );
      });
    });

    test('explicit permissionMode wins over approval', () async {
      ProcessSpawn? spawn;
      final harness = buildClaudeHarness(
        providerOptions: const {'approval': 'never', 'permissionMode': 'plan'},
        processFactory: capturingInitFactory(onSpawn: (value) => spawn = value),
      );
      addTearDown(harness.dispose);

      await harness.start();

      expect(spawn!.args, containsAllInOrder(['--permission-mode', 'plan']));
      expect(spawn!.args, isNot(contains('bypassPermissions')));
      expect(spawn!.environment!['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], isNot('0'));

      final hostRoot = await Directory.systemTemp.createTemp('dartclaw-claude-restricted-precedence-');
      addTearDown(() => hostRoot.delete(recursive: true));
      final restrictedHarness = buildClaudeHarness(
        providerOptions: const {'approval': 'never', 'permissionMode': 'plan'},
        containerManager: FakeClaudeContainerExecutor(
          hostRoot: hostRoot.path,
          containerRoot: '/workspace',
          profileId: 'restricted',
        ),
      );
      addTearDown(restrictedHarness.dispose);

      await expectLater(restrictedHarness.start(), completes);
    });

    for (final approval in ['on-request', 'unless-allow-listed']) {
      test('approval $approval adds no permission-mode override', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(providerOptions: {'approval': approval});

        expect(capturedArgs, isNot(contains('--permission-mode')));
      });
    }

    test('approval never is refused under the restricted container profile', () async {
      final hostRoot = await Directory.systemTemp.createTemp('dartclaw-claude-restricted-');
      addTearDown(() => hostRoot.delete(recursive: true));
      final harness = buildClaudeHarness(
        providerOptions: const {'approval': 'never'},
        containerManager: FakeClaudeContainerExecutor(
          hostRoot: hostRoot.path,
          containerRoot: '/workspace',
          profileId: 'restricted',
        ),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.start(),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('full-access permission mode'))),
      );
    });

    test('unexpected can_use_tool while permissions are skipped is denied', () async {
      final fake = makeCapturingClaudeProcess();
      final harness = buildClaudeHarness(processFactory: capturingInitFactory(process: fake));
      addTearDown(() async => harness.dispose());

      await harness.start();
      fake.emitStdout(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'req-can-use-tool',
          'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'tool_use_id': 'tool-123'},
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final response = fake.capturedStdinJson.lastWhere(
        (line) => (line['response'] as Map<String, dynamic>)['request_id'] == 'req-can-use-tool',
      );
      expect(response, {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-can-use-tool',
          'response': {'behavior': 'deny', 'toolUseID': 'tool-123'},
        },
      });
    });
  });
}
