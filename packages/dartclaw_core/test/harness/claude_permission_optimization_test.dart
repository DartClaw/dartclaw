import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ClaudeCodeHarness;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show GuardChain;
import 'package:logging/logging.dart';
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

    for (final declaredTools in <List<String>>[
      const ['shell'],
      const [],
    ]) {
      test('host dontAsk argv and scrub with ${declaredTools.isEmpty ? 'no' : 'shell'} grants', () async {
        ProcessSpawn? spawn;
        final harness = buildClaudeHarness(
          providerOptions: const {'permissionMode': 'dontAsk'},
          declaredCanonicalTools: declaredTools,
          processFactory: capturingInitFactory(onSpawn: (value) => spawn = value),
        );
        addTearDown(harness.dispose);

        await harness.start();

        expect(spawn!.args, containsAllInOrder(['--permission-mode', 'dontAsk', '--permission-prompts', 'none']));
        expect(spawn!.args, isNot(contains('--dangerously-skip-permissions')));
        expect(spawn!.args, isNot(contains('--permission-prompt-tool')));
        expect(spawn!.environment!['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '1');
      });
    }

    test('unsupported no-prompt flag refuses before turn', () async {
      final probes = <List<String>>[];
      var spawns = 0;
      final harness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        commandProbe: (exe, args) async {
          probes.add(args);
          if (args.contains('--help')) return processResult(stdout: 'Usage: claude [options]');
          return processResult(stdout: '1.0.0');
        },
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawns++;
          return makeClaudeFakeProcess();
        },
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.start(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'diagnosis',
            allOf(contains('claude'), contains('--permission-prompts none'), contains('compatible Claude CLI')),
          ),
        ),
      );
      expect(probes, anyElement(equals(['--help'])));
      expect(spawns, 0);
    });

    test('unsupported no-prompt flag refuses before turn on restart', () async {
      var noPromptProbes = 0;
      var spawns = 0;
      final harness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        commandProbe: (exe, args) async {
          if (args.contains('--help')) {
            if (++noPromptProbes == 2) return processResult(stdout: 'Usage: claude [options]');
            return processResult(stdout: '--permission-prompts <target> "none"');
          }
          return processResult(stdout: '1.0.0');
        },
        processFactory: capturingInitFactory(onSpawn: (_) => spawns++),
      );
      addTearDown(harness.dispose);
      await harness.start();

      await expectLater(
        harness.turn(
          sessionId: 'new-session',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          directory: '/tmp/another-directory',
        ),
        throwsA(isA<Exception>().having((error) => error.toString(), 'diagnosis', contains('compatible Claude CLI'))),
      );
      expect(noPromptProbes, 2);
      expect(spawns, 1);
    });

    test('unsupported no-prompt flag does not relabel version or auth failures', () async {
      final versionHarness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        commandProbe: (exe, args) async => processResult(exitCode: 1),
      );
      addTearDown(versionHarness.dispose);
      await expectLater(
        versionHarness.start(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'diagnosis',
            allOf(contains('--version'), isNot(contains('permission-prompts'))),
          ),
        ),
      );

      final authHarness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        environment: const {},
        commandProbe: (exe, args) async =>
            args.first == '--version' ? processResult(stdout: '1.0.0') : processResult(exitCode: 1),
      );
      addTearDown(authHarness.dispose);
      await expectLater(
        authHarness.start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'diagnosis',
            allOf(contains('No authentication configured'), isNot(contains('permission-prompts'))),
          ),
        ),
      );
    });

    test('reports effective host permission posture without a credential value', () async {
      final messages = <String>[];
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'ClaudeCodeHarness') messages.add(record.message);
      });
      addTearDown(subscription.cancel);
      final harness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        environment: const {'ANTHROPIC_API_KEY': 'synthetic-secret'},
        guardChain: GuardChain(guards: [RecordingGuard()]),
      );
      addTearDown(harness.dispose);

      await harness.start();

      expect(messages, contains(contains('requested=dontAsk, native=default, prompts=none')));
      expect(messages.join(' '), contains('subprocess env scrub=1, PreToolUse guards=active'));
      expect(messages.join(' '), isNot(contains('synthetic-secret')));
    });

    for (final inheritUserSettings in [null, true]) {
      for (final declaredTools in <List<String>?>[
        null,
        const ['shell'],
        const [],
      ]) {
        test('inherit_user_settings ${inheritUserSettings ?? 'default'} inherits user settings '
            'with ${declaredTools == null
                ? 'no declared tool list'
                : declaredTools.isEmpty
                ? 'an empty declared tool list'
                : 'a declared tool list'}', () async {
          final capturedArgs = await startHarnessAndCaptureArgs(
            providerOptions: {'permissionMode': 'dontAsk', 'inherit_user_settings': ?inheritUserSettings},
            declaredCanonicalTools: declaredTools,
          );

          expect(capturedArgs, isNot(contains('--setting-sources')));
        });
      }
    }

    for (final declaredTools in <List<String>?>[
      null,
      const ['shell'],
      const [],
    ]) {
      test('inherit_user_settings false uses project settings '
          'with ${declaredTools == null
              ? 'no declared tool list'
              : declaredTools.isEmpty
              ? 'an empty declared tool list'
              : 'a declared tool list'}', () async {
        final capturedArgs = await startHarnessAndCaptureArgs(
          providerOptions: const {'permissionMode': 'dontAsk', 'inherit_user_settings': false},
          declaredCanonicalTools: declaredTools,
        );

        expect(capturedArgs, containsAllInOrder(['--setting-sources', 'project']));
      });
    }

    test('a pre-execution step spawn derives no grants from the server cwd', () async {
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
      expect(allow, isEmpty, reason: 'an unknown execution directory must add no declared-tool grants');
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

    test('interactive and omitted modes have no host-only no-prompt flag', () async {
      for (final options in <Map<String, dynamic>>[
        const {'permissionMode': 'default'},
        const {'permissionMode': 'plan'},
        const {'approval': 'never'},
        const {},
      ]) {
        ProcessSpawn? spawn;
        final harness = buildClaudeHarness(
          providerOptions: options,
          processFactory: capturingInitFactory(onSpawn: (value) => spawn = value),
        );
        addTearDown(harness.dispose);
        await harness.start();
        expect(spawn!.args, isNot(contains('--permission-prompts')));
        if (options['approval'] != 'never') {
          expect(spawn!.environment!['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '1');
        }
      }
    });

    test('container dontAsk keeps its separate scrub and prompt policy', () async {
      final hostRoot = await Directory.systemTemp.createTemp('dartclaw-claude-container-permission-');
      addTearDown(() => hostRoot.delete(recursive: true));
      final container = FakeClaudeContainerExecutor(hostRoot: hostRoot.path, containerRoot: '/workspace');
      final harness = buildClaudeHarness(
        providerOptions: const {'permissionMode': 'dontAsk'},
        containerManager: container,
      );
      addTearDown(harness.dispose);
      await harness.start();
      expect(container.lastCommand, isNot(contains('--permission-prompts')));
      expect(container.lastEnv!['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '0');
      expect(container.lastEnv!['ANTHROPIC_API_KEY'], 'dartclaw-host-mediated-no-credential');
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
