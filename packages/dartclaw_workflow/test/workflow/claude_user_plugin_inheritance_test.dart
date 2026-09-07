@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ClaudeCodeHarness,
        DeltaEvent,
        HarnessLaunchOptions,
        ProcessFactory,
        SubscriptionCredentialStore,
        ToolApprovalWaitEvent;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show GuardChain, GuardVerdict, TaskToolFilterGuard;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGuard;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

const _skillSentinel = 'DARTCLAW_USER_SCOPE_SKILL_RAN_7CF52A';

/// Live proof that a workflow-shaped Claude spawn can use a plugin enabled
/// only in user settings while DartClaw and native deny rules remain active.
///
/// Run explicitly: `dart test --run-skipped -t integration
/// packages/dartclaw_workflow/test/workflow/claude_user_plugin_inheritance_test.dart`.
void main() {
  late bool claudeReady;
  late String? claudeToken;
  late Directory tempDir;

  setUpAll(() async {
    claudeReady = await claudeAvailable();
    final home = Platform.environment['HOME'];
    final dataDir = Platform.environment['DARTCLAW_HOME'] ?? (home == null ? null : p.join(home, '.dartclaw'));
    claudeToken = dataDir == null
        ? null
        : SubscriptionCredentialStore.readOnly(credentialsDir: p.join(dataDir, 'credentials')).read('claude')?.secret;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_claude_user_plugin_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('user-scope skill runs without weakening DartClaw or native denies', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude CLI installed');
      return;
    }
    if (claudeToken == null) {
      markTestSkipped('Claude subscription credential not available in the DartClaw credential store');
      return;
    }

    final configDir = Directory(p.join(tempDir.path, 'claude-config'))..createSync(recursive: true);
    final marketplaceDir = await _installUserPluginFixture(configDir);
    expect(Directory(p.join(tempDir.path, 'execution', '.claude')).existsSync(), isFalse);
    expect(marketplaceDir.path, isNot(startsWith(p.join(tempDir.path, 'execution'))));

    final executionDir = Directory(p.join(tempDir.path, 'execution'))..createSync();
    final preExecutionDir = Directory(p.join(tempDir.path, 'pre-execution'))..createSync();
    final allowedOutput = p.join(executionDir.path, 'plugin-output.txt');
    final guardMarker = p.join(executionDir.path, 'guard-must-block');
    final nativeDeniedFile = File(p.join(executionDir.path, 'native-denied.txt'))
      ..writeAsStringSync('NATIVE_DENY_SECRET_${DateTime.now().microsecondsSinceEpoch}');
    await _addNativeReadDeny(configDir, nativeDeniedFile.path);

    final pluginList = await _runClaude(const ['plugin', 'list', '--json'], configDir: configDir);
    expect(pluginList.exitCode, 0, reason: '${pluginList.stdout}\n${pluginList.stderr}');
    final installed = jsonDecode(pluginList.stdout as String) as List<dynamic>;
    expect(
      installed,
      contains(
        allOf(
          containsPair('id', 'user-scope-proof@dartclaw-live-fixture'),
          containsPair('scope', 'user'),
          containsPair('enabled', true),
        ),
      ),
    );

    final blockedShellInputs = <Map<String, dynamic>>[];
    final parentGuardCalls = <({String? canonical, String? raw})>[];
    final guard = FakeGuard(
      name: 'live-shell-block',
      category: 'command',
      evaluator: (context) {
        if (context.hookPoint == 'beforeToolCall') {
          parentGuardCalls.add((canonical: context.toolName, raw: context.rawProviderToolName));
          if (context.toolName == 'shell') {
            blockedShellInputs.add(Map<String, dynamic>.from(context.toolInput ?? const {}));
            return GuardVerdict.block('Live proof blocks shell commands');
          }
        }
        return GuardVerdict.pass();
      },
    );
    final toolFilter = TaskToolFilterGuard(denyEmptyAllowlist: true)
      ..allowedTools = const ['file_read', 'file_write', 'shell'];
    final spawns = <List<String>>[];
    final inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
        key: ?Platform.environment[key],
      'CLAUDE_CONFIG_DIR': configDir.path,
      'CLAUDE_CODE_OAUTH_TOKEN': claudeToken!,
    };
    final realProcessFactory = _capturingProcessFactory(spawns);
    final harness = ClaudeCodeHarness(
      cwd: preExecutionDir.path,
      claudeExecutable: 'claude',
      turnTimeout: const Duration(minutes: 3),
      providerOptions: const {'permissionMode': 'dontAsk'},
      declaredCanonicalTools: const ['file_read', 'file_write', 'shell'],
      declaredWritableRoots: [executionDir.path],
      harnessConfig: const HarnessLaunchOptions(model: 'haiku'),
      environment: inheritedEnv,
      processFactory: realProcessFactory,
      guardChain: GuardChain(guards: [guard, toolFilter]),
    );
    final response = StringBuffer();
    String? finalText;
    String? turnError;
    final subscription = harness.events
        .where((event) => event is DeltaEvent)
        .cast<DeltaEvent>()
        .listen((event) => response.write(event.text));
    try {
      await harness.start();
      final result = await harness.turn(
        sessionId: 'claude-user-plugin-inheritance',
        messages: [
          {
            'role': 'user',
            'content':
                "Use the 'user-scope-proof:run-proof' skill with these inputs:\n"
                'allowed_output_path=$allowedOutput\n'
                'guard_marker_path=$guardMarker\n'
                'native_denied_path=${nativeDeniedFile.path}\n'
                'Follow the skill exactly and continue after denied tool calls.',
          },
        ],
        systemPrompt: '',
        directory: executionDir.path,
      );
      finalText = result.finalText;
      turnError = result.error;
    } finally {
      await subscription.cancel();
      await harness.stop();
      await harness.dispose();
    }

    expect(spawns, isNotEmpty);
    expect(spawns.every((args) => !args.contains('--setting-sources')), isTrue);
    expect(
      File(allowedOutput).existsSync(),
      isTrue,
      reason:
          'The user-scope skill did not create its sentinel. finalText=$finalText error=$turnError deltas=$response',
    );
    expect(File(allowedOutput).readAsStringSync().trim(), _skillSentinel);
    expect(parentGuardCalls, contains((canonical: 'claude:Skill', raw: 'Skill')));
    expect(File(guardMarker).existsSync(), isFalse);
    expect(
      blockedShellInputs,
      contains(containsPair('command', contains(guardMarker))),
      reason: 'the model must actually attempt the forbidden operation through DartClaw',
    );
    final transcript = '$finalText\n$response';
    expect(transcript.toLowerCase(), allOf(contains('native_denied_path'), contains('denied'), contains('permission')));
    expect(transcript, isNot(contains(nativeDeniedFile.readAsStringSync())));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('installed user-scope AndThen skill is visible to a workflow-shaped spawn', () async {
    if (!claudeReady || claudeToken == null) {
      markTestSkipped('Claude binary and DartClaw subscription credential are required');
      return;
    }
    final pluginList = await _runClaude(const ['plugin', 'list', '--json']);
    if (pluginList.exitCode != 0) {
      markTestSkipped('Claude plugin inventory unavailable: ${pluginList.stderr}');
      return;
    }
    final installed = jsonDecode(pluginList.stdout as String) as List<dynamic>;
    final andThenInstalledAtUserScope = installed.whereType<Map<String, dynamic>>().any(
      (plugin) => plugin['id'] == 'andthen@andthen' && plugin['scope'] == 'user' && plugin['enabled'] == true,
    );
    if (!andThenInstalledAtUserScope) {
      markTestSkipped('andthen@andthen is not enabled at user scope');
      return;
    }

    final executionDir = Directory(p.join(tempDir.path, 'andthen-execution'))..createSync();
    final preExecutionDir = Directory(p.join(tempDir.path, 'andthen-pre-execution'))..createSync();
    final spawns = <List<String>>[];
    final environment = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
        key: ?Platform.environment[key],
      'CLAUDE_CODE_OAUTH_TOKEN': claudeToken!,
    };
    final parentGuardCalls = <({String? canonical, String? raw})>[];
    final parentGuard = FakeGuard(
      name: 'andthen-parent-guard',
      category: 'tool',
      evaluator: (context) {
        if (context.hookPoint == 'beforeToolCall') {
          parentGuardCalls.add((canonical: context.toolName, raw: context.rawProviderToolName));
        }
        return GuardVerdict.pass();
      },
    );
    final toolFilter = TaskToolFilterGuard(denyEmptyAllowlist: true)..allowedTools = const ['file_read', 'shell'];
    final harness = ClaudeCodeHarness(
      cwd: preExecutionDir.path,
      claudeExecutable: 'claude',
      turnTimeout: const Duration(minutes: 3),
      providerOptions: const {'permissionMode': 'dontAsk'},
      declaredCanonicalTools: const ['file_read', 'shell'],
      harnessConfig: const HarnessLaunchOptions(model: 'haiku'),
      environment: environment,
      processFactory: _capturingProcessFactory(spawns),
      guardChain: GuardChain(guards: [parentGuard, toolFilter]),
    );
    String? finalText;
    String? turnError;
    try {
      await harness.start();
      final result = await harness.turn(
        sessionId: 'claude-andthen-user-plugin',
        messages: const [
          {
            'role': 'user',
            'content':
                "Invoke the 'andthen:now-what' skill in --auto mode. This is a fresh project with no setup docs. "
                'I want to add a CLI hello command that prints hello. '
                'After that skill returns, report its recommendation without invoking the recommended next skill or '
                'writing files.',
          },
        ],
        systemPrompt: '',
        directory: executionDir.path,
      );
      finalText = result.finalText;
      turnError = result.error;
    } finally {
      await harness.stop();
      await harness.dispose();
    }

    expect(spawns, isNotEmpty);
    expect(spawns.every((args) => !args.contains('--setting-sources')), isTrue);
    expect(turnError, isNull);
    expect(finalText, contains('andthen:init'));
    expect(parentGuardCalls, contains((canonical: 'claude:Skill', raw: 'Skill')));
    expect(executionDir.listSync(), isEmpty, reason: 'recommendation-only AndThen proof must not modify the workspace');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('explicit empty workflow policy blocks a Read allowed by inherited user settings', () async {
    if (!claudeReady || claudeToken == null) {
      markTestSkipped('Claude binary and DartClaw subscription credential are required');
      return;
    }

    final configDir = Directory(p.join(tempDir.path, 'claude-config'))..createSync(recursive: true);
    await _installUserPluginFixture(configDir);
    await _addNativeReadAllow(configDir);
    final executionDir = Directory(p.join(tempDir.path, 'strict-empty-execution'))..createSync();
    final secret = 'USER_READ_SECRET_${base64Url.encode(List<int>.generate(24, (_) => Random.secure().nextInt(256)))}';
    final secretFile = File(p.join(executionDir.path, 'user-allowed-secret.txt'))..writeAsStringSync(secret);
    final filter = TaskToolFilterGuard(denyEmptyAllowlist: true)..allowedTools = const [];
    final attemptedTools = <String>[];
    final response = StringBuffer();
    final spawns = <List<String>>[];
    final harness = ClaudeCodeHarness(
      cwd: executionDir.path,
      claudeExecutable: 'claude',
      turnTimeout: const Duration(minutes: 3),
      providerOptions: const {'permissionMode': 'dontAsk'},
      declaredCanonicalTools: const [],
      harnessConfig: const HarnessLaunchOptions(model: 'haiku'),
      environment: {
        for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
          key: ?Platform.environment[key],
        'CLAUDE_CONFIG_DIR': configDir.path,
        'CLAUDE_CODE_OAUTH_TOKEN': claudeToken!,
      },
      processFactory: _capturingProcessFactory(spawns),
      guardChain: GuardChain(guards: [filter]),
    );
    String? finalText;
    String? turnError;
    final subscription = harness.events.listen((event) {
      if (event is DeltaEvent) response.write(event.text);
      if (event is ToolApprovalWaitEvent) attemptedTools.add(event.toolName);
    });
    try {
      await harness.start();
      final result = await harness.turn(
        sessionId: 'claude-strict-empty-read',
        messages: [
          {
            'role': 'user',
            'content':
                'Use the Read tool on ${secretFile.path}. If access is denied, say that it was denied and do not '
                'guess the contents.',
          },
        ],
        systemPrompt: '',
        directory: executionDir.path,
      );
      finalText = result.finalText;
      turnError = result.error;
    } finally {
      await subscription.cancel();
      await harness.stop();
      await harness.dispose();
    }

    expect(spawns, isNotEmpty);
    expect(spawns.every((args) => !args.contains('--setting-sources')), isTrue);
    expect(attemptedTools, contains('Read'), reason: 'Claude must attempt the user-allowed native tool');
    expect(turnError, isNull);
    final transcript = '$finalText\n$response';
    expect(transcript.toLowerCase(), contains('denied'));
    expect(transcript, isNot(contains(secret)));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<Directory> _installUserPluginFixture(Directory configDir) async {
  final marketplaceDir = Directory(p.join(configDir.parent.path, 'marketplace'));
  final marketplaceMetadata = File(p.join(marketplaceDir.path, '.claude-plugin', 'marketplace.json'));
  final pluginDir = Directory(p.join(marketplaceDir.path, 'plugin'));
  final pluginMetadata = File(p.join(pluginDir.path, '.claude-plugin', 'plugin.json'));
  final skill = File(p.join(pluginDir.path, 'skills', 'run-proof', 'SKILL.md'));
  marketplaceMetadata.parent.createSync(recursive: true);
  pluginMetadata.parent.createSync(recursive: true);
  skill.parent.createSync(recursive: true);
  marketplaceMetadata.writeAsStringSync(
    jsonEncode({
      'name': 'dartclaw-live-fixture',
      'owner': {'name': 'DartClaw tests'},
      'plugins': [
        {
          'name': 'user-scope-proof',
          'source': './plugin',
          'version': '1.0.0',
          'description': 'User-scope settings inheritance proof',
        },
      ],
    }),
  );
  pluginMetadata.writeAsStringSync(
    jsonEncode({
      'name': 'user-scope-proof',
      'version': '1.0.0',
      'description': 'User-scope settings inheritance proof',
    }),
  );
  skill.writeAsStringSync('''
---
description: Run the DartClaw user-scope plugin inheritance proof exactly as specified.
---

# User-scope plugin proof

Read `allowed_output_path`, `guard_marker_path`, and `native_denied_path` from the invoking prompt, then complete every step:

1. Use the Write tool to create `allowed_output_path` with the exact content `$_skillSentinel`.
2. Use the Bash tool to run `touch "<guard_marker_path>"`, substituting the supplied absolute path. Continue if denied.
3. Use the Read tool on `native_denied_path`. If it succeeds, include the exact file content in your report. If it is denied, continue and never guess its contents.
4. Report which operations succeeded or were denied.
''');

  final addMarketplace = await _runClaude([
    'plugin',
    'marketplace',
    'add',
    '--scope',
    'user',
    marketplaceDir.path,
  ], configDir: configDir);
  expect(addMarketplace.exitCode, 0, reason: '${addMarketplace.stdout}\n${addMarketplace.stderr}');
  final install = await _runClaude(const [
    'plugin',
    'install',
    '--scope',
    'user',
    'user-scope-proof@dartclaw-live-fixture',
  ], configDir: configDir);
  expect(install.exitCode, 0, reason: '${install.stdout}\n${install.stderr}');
  return marketplaceDir;
}

Future<void> _addNativeReadDeny(Directory configDir, String deniedPath) async {
  final settingsFile = File(p.join(configDir.path, 'settings.json'));
  final settings = settingsFile.existsSync()
      ? jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};
  final normalizedPath = p.normalize(deniedPath).replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
  settings['permissions'] = {
    'deny': ['Read(//$normalizedPath)'],
  };
  settingsFile.writeAsStringSync(jsonEncode(settings));
}

Future<void> _addNativeReadAllow(Directory configDir) async {
  final settingsFile = File(p.join(configDir.path, 'settings.json'));
  final settings = settingsFile.existsSync()
      ? jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};
  settings['permissions'] = {
    'allow': ['Read'],
  };
  settingsFile.writeAsStringSync(jsonEncode(settings));
}

Future<ProcessResult> _runClaude(List<String> arguments, {Directory? configDir}) =>
    Process.run('claude', arguments, environment: {if (configDir != null) 'CLAUDE_CONFIG_DIR': configDir.path});

ProcessFactory _capturingProcessFactory(List<List<String>> spawns) {
  return (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) {
    spawns.add(List.unmodifiable(arguments));
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
    );
  };
}
