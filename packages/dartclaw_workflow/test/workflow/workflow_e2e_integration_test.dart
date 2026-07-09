@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowStepCompletedEvent;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowPublishStatus,
        WorkflowStepOutputTransformer;
import 'package:dartclaw_server/dartclaw_server.dart' show LogService;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../fixtures/e2e_fixture.dart';
import '_support/workflow_test_paths.dart';
import 'workflow_e2e_test_support.dart';

typedef _WorkflowE2eProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

WorkflowStepOutputTransformer _forceSinglePlanReviewRemediationLoop({
  required String remediationPlan,
  required String implementationSummary,
  required Set<String> targetReviews,
}) {
  final forcedTargets = <String>{};
  final log = Logger('E2E.ForcedRemediation');
  return (run, definition, step, task, outputs) {
    if (definition.name != 'plan-and-implement' ||
        !targetReviews.contains(step.id) ||
        forcedTargets.contains(step.id)) {
      return outputs;
    }
    final transformed = forcedReviewRemediationOutputs(
      stepId: step.id,
      outputs: outputs,
      targetReviews: targetReviews,
      remediationPlan: remediationPlan,
      implementationSummary: implementationSummary,
    );
    if (identical(transformed, outputs)) {
      return outputs;
    }

    forcedTargets.add(step.id);
    log.info(
      'Forcing a single remediation-loop iteration for workflow ${run.id} '
      'by overriding clean ${step.id} outputs',
    );
    return transformed;
  };
}

Future<void> _closePr(String prUrl) async {
  if (prUrl.isEmpty) return;
  await Process.run('gh', ['pr', 'close', prUrl, '--delete-branch']);
}

Future<void> _closePrByBranch(String branch, String repo, {String? projectDir}) async {
  await closePrByBranch(branch: branch, repo: repo, projectDir: projectDir);
}

Future<String?> _githubTokenFromEnvOrGh() async {
  final envToken = Platform.environment['GITHUB_TOKEN']?.trim();
  if (envToken != null && envToken.isNotEmpty) return envToken;

  final result = await Process.run('gh', ['auth', 'token']);
  if (result.exitCode != 0) return null;
  final token = (result.stdout as String).trim();
  return token.isEmpty ? null : token;
}

Future<void> _cloneTodoAppFixtureRepo(String targetDir, {String? githubToken}) async {
  await _cloneTodoAppFixtureRepoWithRunner(targetDir, githubToken: githubToken);
}

Future<void> _cloneTodoAppFixtureRepoWithRunner(
  String targetDir, {
  String? githubToken,
  _WorkflowE2eProcessRunner runProcess = Process.run,
  Map<String, String>? environment,
  Directory? cacheRootOverride,
}) async {
  Directory(targetDir).parent.createSync(recursive: true);

  final resolvedToken = githubToken?.trim();
  const publicCloneUri = 'https://github.com/DartClaw/workflow-test-todo-app.git';
  final cloneEnv = <String, String>{'GIT_TERMINAL_PROMPT': '0'};
  final env = environment ?? Platform.environment;
  final offline = env['DARTCLAW_E2E_FIXTURE_OFFLINE']?.trim().toLowerCase() == 'true';
  final cacheRoot = cacheRootOverride ?? Directory(p.join(workflowFixturesRoot(), '.cache', 'workflow-test-todo-app'));

  _GitCredentialHelper? credentialHelper;
  try {
    String? remoteHeadSha;
    if (!offline) {
      var result = await runProcess('git', ['ls-remote', publicCloneUri, 'HEAD'], environment: cloneEnv);
      if (result.exitCode != 0 && resolvedToken != null && resolvedToken.isNotEmpty) {
        credentialHelper ??= _GitCredentialHelper.create(resolvedToken);
        result = await runProcess(
          'git',
          credentialHelper.arguments(['ls-remote', publicCloneUri, 'HEAD']),
          environment: cloneEnv,
        );
      }
      if (result.exitCode != 0) {
        throw StateError(
          'Failed to resolve workflow-test-todo-app fixture HEAD over HTTPS: '
          '${_redactGitOutput(result.stderr, resolvedToken)}\n'
          'Tip: set GITHUB_TOKEN for authenticated HTTPS if GitHub rate-limits anonymous ls-remote.',
        );
      }
      remoteHeadSha = _parseLsRemoteHead(result.stdout as String);
    }

    final cacheDir = offline ? _latestUsableFixtureCache(cacheRoot) : Directory(p.join(cacheRoot.path, remoteHeadSha!));
    if (cacheDir == null) {
      throw StateError(
        'DARTCLAW_E2E_FIXTURE_OFFLINE=true requires a valid cached workflow-test-todo-app fixture under '
        '${cacheRoot.path}.',
      );
    }
    if (!cacheDir.existsSync()) {
      if (offline) {
        throw StateError(
          'DARTCLAW_E2E_FIXTURE_OFFLINE=true requires a valid cached workflow-test-todo-app fixture under '
          '${cacheRoot.path}.',
        );
      }

      cacheDir.parent.createSync(recursive: true);
      final stagingDir = Directory('${cacheDir.path}.tmp.${DateTime.now().microsecondsSinceEpoch}');
      if (stagingDir.existsSync()) {
        stagingDir.deleteSync(recursive: true);
      }
      final cloneArgs = ['clone', '--depth', '1', publicCloneUri, stagingDir.path];
      var result = await runProcess('git', cloneArgs, environment: cloneEnv);
      if (result.exitCode != 0 && resolvedToken != null && resolvedToken.isNotEmpty) {
        credentialHelper ??= _GitCredentialHelper.create(resolvedToken);
        result = await runProcess('git', credentialHelper.arguments(cloneArgs), environment: cloneEnv);
      }
      if (result.exitCode != 0) {
        if (stagingDir.existsSync()) {
          stagingDir.deleteSync(recursive: true);
        }
        throw StateError(
          'Failed to clone workflow-test-todo-app fixture repo over HTTPS: '
          '${_redactGitOutput(result.stderr, resolvedToken)}\n'
          'Tip: set GITHUB_TOKEN for authenticated HTTPS if GitHub rate-limits anonymous clone.',
        );
      }
      await _setOriginUrl(stagingDir.path, publicCloneUri);
      try {
        stagingDir.renameSync(cacheDir.path);
      } on FileSystemException {
        if (stagingDir.existsSync()) {
          stagingDir.deleteSync(recursive: true);
        }
        if (!_isUsableFixtureCache(cacheDir)) {
          rethrow;
        }
      }
    }
    if (!_isUsableFixtureCache(cacheDir)) {
      throw StateError('Invalid cached workflow-test-todo-app fixture under ${cacheDir.path}.');
    }
    await _setOriginUrl(cacheDir.path, publicCloneUri);

    final target = Directory(targetDir);
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    await _cloneCachedFixtureRepo(cacheDir, target);
    await _setOriginUrl(targetDir, publicCloneUri);
    Process.runSync('git', ['config', 'user.name', 'Workflow E2E Test'], workingDirectory: targetDir);
    Process.runSync('git', ['config', 'user.email', 'workflow-e2e@example.com'], workingDirectory: targetDir);
    assertKnownDefectsBacklogEntries(targetDir);
  } finally {
    credentialHelper?.dispose();
  }
}

String _parseLsRemoteHead(String output) {
  final line = output.split('\n').map((value) => value.trim()).firstWhere((value) => value.isNotEmpty);
  final sha = line.split(RegExp(r'\s+')).first;
  if (sha.isEmpty) {
    throw StateError('Unable to parse workflow-test-todo-app HEAD SHA from ls-remote output: $output');
  }
  return sha;
}

Directory? _latestUsableFixtureCache(Directory cacheRoot) {
  if (!cacheRoot.existsSync()) return null;
  final candidates = cacheRoot.listSync().whereType<Directory>().toList();
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  for (final candidate in candidates) {
    if (_isUsableFixtureCache(candidate)) {
      return candidate;
    }
  }
  return null;
}

bool _isUsableFixtureCache(Directory cacheDir) =>
    Directory(p.join(cacheDir.path, '.git')).existsSync() &&
    File(p.join(cacheDir.path, 'docs', 'PRODUCT-BACKLOG.md')).existsSync();

Future<void> _cloneCachedFixtureRepo(Directory cacheDir, Directory target) async {
  final result = await Process.run('git', ['clone', '--no-hardlinks', cacheDir.path, target.path]);
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to clone cached workflow-test-todo-app fixture from ${cacheDir.path}: ${_redactGitOutput(result.stderr)}',
    );
  }
}

String _redactGitOutput(Object? output, [String? token]) {
  var text = output?.toString() ?? '';
  if (token != null && token.isNotEmpty) {
    text = text.replaceAll(token, '<redacted>');
  }
  return text.replaceAll(RegExp(r'x-access-token:[^@\s]+@'), 'x-access-token:<redacted>@');
}

String _shellSingleQuotedBody(String value) => value.replaceAll("'", "'\"'\"'");

final class _GitCredentialHelper {
  final Directory _directory;
  final String path;

  _GitCredentialHelper._(this._directory, this.path);

  static _GitCredentialHelper create(String token) {
    final directory = Directory.systemTemp.createTempSync('dartclaw_fixture_git_credentials_');
    final helper = File(p.join(directory.path, 'credential-helper'));
    final escapedToken = _shellSingleQuotedBody(token);
    helper.writeAsStringSync(
      '#!/bin/sh\n'
      'if [ "\$1" = "get" ]; then\n'
      "  printf '%s\\n' 'username=x-access-token' 'password=$escapedToken'\n"
      'fi\n',
    );
    Process.runSync('chmod', ['700', directory.path]);
    Process.runSync('chmod', ['700', helper.path]);
    return _GitCredentialHelper._(directory, helper.path);
  }

  List<String> arguments(List<String> gitCommand) => [
    '-c',
    'credential.helper=',
    '-c',
    'credential.helper=$path',
    ...gitCommand,
  ];

  void dispose() {
    if (_directory.existsSync()) {
      _directory.deleteSync(recursive: true);
    }
  }
}

_WorkflowE2eProcessRunner _fakeFixtureGitRunner({
  required List<String> heads,
  required void Function(String targetDir) onClone,
}) {
  var headIndex = 0;
  return (executable, arguments, {workingDirectory, environment}) async {
    if (executable != 'git') return ProcessResult(0, 1, '', 'unexpected executable $executable');
    final gitArguments = _stripGitConfigArguments(arguments);
    if (gitArguments.length >= 3 && gitArguments[0] == 'ls-remote') {
      final sha = heads[headIndex < heads.length ? headIndex : heads.length - 1];
      headIndex++;
      return ProcessResult(0, 0, '$sha\tHEAD\n', '');
    }
    if (gitArguments.length >= 4 && gitArguments[0] == 'clone') {
      onClone(gitArguments.last);
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 1, '', 'unexpected git arguments: ${arguments.join(' ')}');
  };
}

List<String> _stripGitConfigArguments(List<String> arguments) {
  var index = 0;
  while (index + 1 < arguments.length && arguments[index] == '-c') {
    index += 2;
  }
  return arguments.sublist(index);
}

void _writeKnownDefectsFixture(String targetDir, {required String marker}) {
  final dir = Directory(targetDir)..createSync(recursive: true);
  File(p.join(dir.path, 'docs', 'PRODUCT-BACKLOG.md'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('BUG-001\nBUG-002\nBUG-003\n');
  File(p.join(dir.path, 'marker.txt')).writeAsStringSync(marker);
  Process.runSync('git', ['init'], workingDirectory: dir.path);
  Process.runSync('git', ['config', 'user.name', 'Workflow E2E Test'], workingDirectory: dir.path);
  Process.runSync('git', ['config', 'user.email', 'workflow-e2e@example.com'], workingDirectory: dir.path);
  Process.runSync('git', [
    'remote',
    'add',
    'origin',
    'https://github.com/DartClaw/workflow-test-todo-app.git',
  ], workingDirectory: dir.path);
  Process.runSync('git', ['add', '.'], workingDirectory: dir.path);
  Process.runSync('git', ['commit', '-m', 'fixture'], workingDirectory: dir.path);
}

Future<void> _setOriginUrl(String projectDir, String url) async {
  final result = await Process.run('git', ['remote', 'set-url', 'origin', url], workingDirectory: projectDir);
  if (result.exitCode != 0) {
    throw StateError('Failed to set fixture origin URL to "$url": ${result.stderr}');
  }
}

Future<void> _redirectOriginToLocalBareRemote(String projectDir) async {
  final originDir = Directory(p.join(Directory(projectDir).parent.path, 'workflow-test-todo-app-origin.git'));
  if (originDir.existsSync()) {
    originDir.deleteSync(recursive: true);
  }
  originDir.createSync(recursive: true);

  var result = await Process.run('git', ['init', '--bare'], workingDirectory: originDir.path);
  if (result.exitCode != 0) {
    throw StateError('Failed to initialize local fixture origin: ${result.stderr}');
  }

  result = await Process.run('git', ['config', 'receive.shallowUpdate', 'true'], workingDirectory: originDir.path);
  if (result.exitCode != 0) {
    throw StateError('Failed to configure local fixture origin: ${result.stderr}');
  }

  await _setOriginUrl(projectDir, originDir.path);

  result = await Process.run('git', ['push', '-u', 'origin', 'HEAD:main'], workingDirectory: projectDir);
  if (result.exitCode != 0) {
    throw StateError('Failed to seed local fixture origin: ${result.stderr}');
  }
}

void main() {
  group('workflow fixture clone cache', () {
    late Directory tempDir;
    late Directory cacheRoot;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_fixture_cache_test_');
      cacheRoot = Directory(p.join(tempDir.path, 'cache'));
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<void> cloneTarget(
      String name, {
      String? githubToken,
      required _WorkflowE2eProcessRunner runProcess,
      Map<String, String>? environment,
    }) {
      return _cloneTodoAppFixtureRepoWithRunner(
        p.join(tempDir.path, name),
        githubToken: githubToken,
        runProcess: runProcess,
        environment: environment,
        cacheRootOverride: cacheRoot,
      );
    }

    test('second run reuses cached clone for the same remote HEAD SHA', () async {
      var cloneCount = 0;
      final runner = _fakeFixtureGitRunner(
        heads: ['abc123', 'abc123'],
        onClone: (targetDir) {
          cloneCount++;
          _writeKnownDefectsFixture(targetDir, marker: 'clone-$cloneCount');
        },
      );

      await cloneTarget('target-1', runProcess: runner);
      await cloneTarget('target-2', runProcess: runner);

      expect(cloneCount, 1);
      expect(File(p.join(tempDir.path, 'target-2', 'marker.txt')).readAsStringSync(), 'clone-1');
      expect(File(p.join(tempDir.path, 'target-2', '.git', 'objects', 'info', 'alternates')).existsSync(), isFalse);
    });

    test('SHA change forces a fresh cached clone', () async {
      var cloneCount = 0;
      final runner = _fakeFixtureGitRunner(
        heads: ['abc123', 'def456'],
        onClone: (targetDir) {
          cloneCount++;
          _writeKnownDefectsFixture(targetDir, marker: 'clone-$cloneCount');
        },
      );

      await cloneTarget('target-1', runProcess: runner);
      await cloneTarget('target-2', runProcess: runner);

      expect(cloneCount, 2);
      expect(File(p.join(tempDir.path, 'target-2', 'marker.txt')).readAsStringSync(), 'clone-2');
    });

    test('offline flag skips ls-remote and reuses cache', () async {
      _writeKnownDefectsFixture(p.join(cacheRoot.path, 'abc123'), marker: 'cached');
      var processCalled = false;

      await cloneTarget(
        'target',
        runProcess: (executable, arguments, {workingDirectory, environment}) async {
          processCalled = true;
          return ProcessResult(0, 1, '', 'unexpected process call');
        },
        environment: {'DARTCLAW_E2E_FIXTURE_OFFLINE': 'true'},
      );

      expect(processCalled, isFalse);
      expect(File(p.join(tempDir.path, 'target', 'marker.txt')).readAsStringSync(), 'cached');
    });

    test('offline flag skips newer invalid caches and reuses older valid cache', () async {
      final olderCache = Directory(p.join(cacheRoot.path, 'abc123'));
      final newerCache = Directory(p.join(cacheRoot.path, 'def456'))..createSync(recursive: true);
      _writeKnownDefectsFixture(olderCache.path, marker: 'older-valid');
      Process.runSync('touch', ['-t', '202601010000', olderCache.path]);
      Process.runSync('touch', ['-t', '202601020000', newerCache.path]);

      await cloneTarget(
        'target',
        runProcess: (executable, arguments, {workingDirectory, environment}) async =>
            ProcessResult(0, 1, '', 'unexpected process call'),
        environment: {'DARTCLAW_E2E_FIXTURE_OFFLINE': 'true'},
      );

      expect(File(p.join(tempDir.path, 'target', 'marker.txt')).readAsStringSync(), 'older-valid');
    });

    test('offline cache rejects incomplete cached fixture before copy', () async {
      Directory(p.join(cacheRoot.path, 'abc123')).createSync(recursive: true);

      expect(
        () => cloneTarget(
          'target',
          runProcess: (executable, arguments, {workingDirectory, environment}) async =>
              ProcessResult(0, 1, '', 'unexpected process call'),
          environment: {'DARTCLAW_E2E_FIXTURE_OFFLINE': 'true'},
        ),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('requires a valid cached'))),
      );
    });

    test('cached fixture still fails fast when known defects are missing', () async {
      final cacheDir = p.join(cacheRoot.path, 'abc123');
      _writeKnownDefectsFixture(cacheDir, marker: 'cached');
      File(p.join(cacheDir, 'docs', 'PRODUCT-BACKLOG.md')).writeAsStringSync('BUG-001\nBUG-002\n');
      Process.runSync('git', ['add', 'docs/PRODUCT-BACKLOG.md'], workingDirectory: cacheDir);
      Process.runSync('git', ['commit', '-m', 'corrupt known defects'], workingDirectory: cacheDir);

      await expectLater(
        () => cloneTarget(
          'target',
          runProcess: (executable, arguments, {workingDirectory, environment}) async =>
              ProcessResult(0, 1, '', 'unexpected process call'),
          environment: {'DARTCLAW_E2E_FIXTURE_OFFLINE': 'true'},
        ),
        throwsA(
          isA<TestFailure>().having((failure) => failure.message, 'message', contains(fixtureSeedRegressionMessage)),
        ),
      );
    });

    test('cached clone origin is sanitized before target reuse', () async {
      final cacheDir = p.join(cacheRoot.path, 'abc123');
      _writeKnownDefectsFixture(cacheDir, marker: 'cached');
      await _setOriginUrl(cacheDir, 'https://x-access-token:secret@github.com/DartClaw/workflow-test-todo-app.git');

      await cloneTarget(
        'target',
        runProcess: (executable, arguments, {workingDirectory, environment}) async =>
            ProcessResult(0, 1, '', 'unexpected process call'),
        environment: {'DARTCLAW_E2E_FIXTURE_OFFLINE': 'true'},
      );

      final cacheOrigin = Process.runSync('git', ['remote', 'get-url', 'origin'], workingDirectory: cacheDir);
      final targetOrigin = Process.runSync('git', [
        'remote',
        'get-url',
        'origin',
      ], workingDirectory: p.join(tempDir.path, 'target'));
      expect((cacheOrigin.stdout as String).trim(), 'https://github.com/DartClaw/workflow-test-todo-app.git');
      expect((targetOrigin.stdout as String).trim(), 'https://github.com/DartClaw/workflow-test-todo-app.git');
    });

    test('authenticated fallback keeps GitHub token out of git arguments and errors', () async {
      const token = 'secret-token';
      final calls = <List<String>>[];

      await expectLater(
        () => cloneTarget(
          'target',
          githubToken: token,
          runProcess: (executable, arguments, {workingDirectory, environment}) async {
            calls.add(arguments);
            return ProcessResult(
              0,
              1,
              '',
              'fatal: https://x-access-token:$token@github.com/DartClaw/workflow-test-todo-app.git $token',
            );
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(isNot(contains(token)), contains('x-access-token:<redacted>@'), contains('<redacted>')),
          ),
        ),
      );

      expect(calls.expand((arguments) => arguments).join('\n'), isNot(contains(token)));
    });
  });

  late String fixtureDir;
  late DartclawConfig config;
  E2EFixtureInstance? fixture;
  final createdPrUrls = <String>[];
  final createdBranches = <String>{};
  var canCreateGitHubPr = false;
  String? githubToken;
  late Map<String, String> fixtureEnvironment;
  late final bool requireCompleted;

  CliWorkflowWiring? wiring;
  LogService? logService;

  final diagnosticSubs = <StreamSubscription<Object>>[];

  setUpAll(() async {
    logService = LogService.fromConfig(level: e2eLogLevelFromEnv(Platform.environment));
    logService!.install();
    requireCompleted = e2eRequireCompletedFromEnv(Platform.environment);

    final prereqs = await evaluateWorkflowE2ePrerequisites(environment: Platform.environment, runProcess: Process.run);
    if (prereqs.shouldSkip) {
      markTestSkipped(prereqs.skipReason!);
      return;
    }
  });

  tearDownAll(() async {
    for (final sub in diagnosticSubs) {
      await sub.cancel();
    }
    diagnosticSubs.clear();
    await logService?.dispose();
  });

  setUp(() async {
    createdPrUrls.clear();
    createdBranches.clear();
    githubToken = await _githubTokenFromEnvOrGh();
    fixtureEnvironment = {
      ...Platform.environment,
      if (githubToken != null && githubToken!.isNotEmpty) 'GITHUB_TOKEN': githubToken!,
    };
    canCreateGitHubPr = await canCreateGitHubPrForEnv(environment: fixtureEnvironment, runProcess: Process.run);
    if (!canCreateGitHubPr) {
      Logger('E2E.Setup').warning(
        'gh PR creation is unavailable; workflow e2e will validate branch publish only. '
        'Export GITHUB_TOKEN or fix `gh auth status` to enable PR URL assertions.',
      );
    }
    final hasToken = githubToken != null && githubToken!.isNotEmpty;
    fixture = await E2EFixture(provisionWorkflowSkills: true, environment: fixtureEnvironment)
        .withProject('workflow-test-todo-app', credentials: hasToken ? 'github-main' : null, localPath: !hasToken)
        .withProjectSetup((projectDir) async {
          await _cloneTodoAppFixtureRepo(projectDir, githubToken: githubToken);
          if (!canCreateGitHubPr) {
            await _redirectOriginToLocalBareRemote(projectDir);
          } else if (!hasToken) {
            await _setOriginUrl(projectDir, 'git@github.com:DartClaw/workflow-test-todo-app.git');
          }
        })
        .build();
    fixtureDir = fixture!.projectDir;
    assertKnownDefectsBacklogEntries(fixtureDir);
    config = fixture!.config;
  });

  tearDown(() async {
    if (wiring != null) {
      await wiring!.dispose();
      wiring = null;
    }

    for (final url in createdPrUrls) {
      await _closePr(url);
    }
    for (final branch in createdBranches) {
      await _closePrByBranch(branch, 'DartClaw/workflow-test-todo-app', projectDir: fixtureDir);
    }

    if (fixture != null) {
      await fixture!.dispose();
      fixture = null;
    }
  });

  Future<String> createPr({required String branch, required String title}) async {
    createdBranches.add(branch);
    final result = await Process.run('gh', [
      'pr',
      'create',
      '--repo',
      'DartClaw/workflow-test-todo-app',
      '--head',
      branch,
      '--base',
      'main',
      '--title',
      title,
      '--body',
      'Automated e2e integration test PR – will be auto-closed.',
      '--draft',
    ], workingDirectory: fixtureDir);
    if (result.exitCode != 0) {
      fail('Failed to create PR for branch "$branch": ${result.stderr}');
    }
    final prUrl = (result.stdout as String).trim();
    createdPrUrls.add(prUrl);
    return prUrl;
  }

  Future<CliWorkflowWiring> wireUp({WorkflowStepOutputTransformer? outputTransformer, String? prTitle}) async {
    final resolvedTitle = prTitle ?? 'E2E workflow run ${DateTime.now().millisecondsSinceEpoch}';
    final w = CliWorkflowWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: fixture!.runtimeCwd,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      workflowStepOutputTransformer: outputTransformer,
      prCreator: canCreateGitHubPr
          ? ({required runId, required projectId, required branch}) async {
              try {
                final url = await createPr(branch: branch, title: resolvedTitle);
                return CliWorkflowPrResult(status: WorkflowPublishStatus.success, prUrl: url);
              } catch (e) {
                return CliWorkflowPrResult(
                  status: WorkflowPublishStatus.failed,
                  prUrl: '',
                  error: 'createPr failed: $e',
                );
              }
            }
          : null,
    );
    await w.wire();
    wiring = w;

    final diagLog = Logger('E2E.Diagnostics');
    diagnosticSubs.add(
      w.eventBus.on<WorkflowStepCompletedEvent>().listen((e) {
        diagLog.info(
          'Step completed: ${e.stepId} [${e.stepIndex + 1}/${e.totalSteps}] '
          '${e.success ? "OK" : "FAILED"} (${e.tokenCount} tokens, task=${e.taskId})',
        );
      }),
    );
    diagnosticSubs.add(
      w.eventBus.on<TaskStatusChangedEvent>().listen((e) {
        diagLog.info('Task ${e.taskId}: ${e.oldStatus} → ${e.newStatus}');
      }),
    );
    diagnosticSubs.add(
      w.eventBus.on<WorkflowRunStatusChangedEvent>().listen((e) {
        diagLog.info('Workflow ${e.runId}: ${e.oldStatus} → ${e.newStatus}');
      }),
    );

    return w;
  }

  Future<WorkflowRunStatus> awaitWorkflowCompletion(EventBus eventBus, String runId) {
    final completer = Completer<WorkflowRunStatus>();
    late final StreamSubscription<WorkflowRunStatusChangedEvent> sub;
    sub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
      if (event.runId != runId) return;
      if (event.newStatus.terminal ||
          event.newStatus == WorkflowRunStatus.paused ||
          event.newStatus == WorkflowRunStatus.awaitingApproval) {
        if (!completer.isCompleted) {
          completer.complete(event.newStatus);
        }
        unawaited(sub.cancel());
      }
    });
    completer.future.whenComplete(() => unawaited(sub.cancel()));
    return completer.future;
  }

  // Primary spec-and-implement live-e2e scenario. It feeds a pre-authored FIS
  // so the run exercises the orchestration-critical steps (detect → implement →
  // reviews → merge → git → PR) without paying for a live authoring turn — the
  // synthesize scenario's only unique live value. The synthesize/existing/
  // low-confidence branch matrix stays covered deterministically by the stubbed
  // workflow_builtin_spec_and_implement_test.dart; live authoring coverage lives
  // in the spec step-isolation probe.
  //
  // TD-114 existing-spec-reuse canary: when FEATURE is a path to an existing
  // implementation spec, detect-spec-input must classify `spec_source ==
  // "existing"` (the restored per-key main-prompt instruction is what tells the
  // model to emit it) so the `spec` step's `spec_source == synthesized` gate is
  // false and the step is skipped, rather than re-synthesizing the reused spec.
  test(
    'spec-and-implement e2e reuses an existing FIS and skips the spec step',
    () async {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final w = await wireUp(prTitle: 'E2E spec-and-implement reuse $timestamp');
      final artifactDir = createPreservedArtifactDir('spec-and-implement-reuse-e2e');
      Logger('E2E.StepArtifacts').info('Preserving step artifacts in ${artifactDir.path}');

      // Seed a reusable implementation spec for BUG-001 into the fixture so the
      // detect-spec-input classifier resolves it as an existing spec on disk.
      const seededSpecPath = 'docs/specs/bug-001/fix-sidebar-incomplete-count.md';
      File(p.join(fixtureDir, seededSpecPath))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '# Fix sidebar incomplete-count on todo deletion\n\n'
          '## Feature Overview and Goal\n\n'
          '**Intent**: Close BUG-001 — the sidebar incomplete-count is not updated '
          'when a todo is deleted; the delete response must refresh the same count '
          'via the existing HTMX out-of-band swap pattern.\n\n'
          '## Acceptance Scenarios\n\n'
          '- When a todo is deleted, the sidebar incomplete-count decreases via an '
          'out-of-band swap, mirroring how toggle_todo updates it.\n\n'
          '## Implementation Plan\n\n'
          '- Update the delete_todo handler to return the same out-of-band count '
          'fragment that toggle_todo returns.\n',
        );
      // The workflow runs in a git worktree checked out from the base branch,
      // so the seeded spec must be committed — an uncommitted working-tree file
      // is invisible there and the classifier would (correctly) report no
      // existing spec. Mirrors the plan-and-implement PRD-seed commit above.
      final addSpec = await Process.run('git', ['add', seededSpecPath], workingDirectory: fixtureDir);
      if (addSpec.exitCode != 0) {
        fail('Failed to stage reusable spec fixture: ${addSpec.stderr}');
      }
      final commitSpec = await Process.run('git', [
        'commit',
        '-qm',
        'Add reusable spec fixture',
      ], workingDirectory: fixtureDir);
      if (commitSpec.exitCode != 0) {
        fail('Failed to commit reusable spec fixture: ${commitSpec.stderr}');
      }

      final definition = w.registry.getByName('spec-and-implement')!;

      final recorder = WorkflowExecutionRecorder(
        w.eventBus,
        w.taskService,
        w.messageService,
        w.workflowService,
        w.kvService,
        definition,
        artifactDir: artifactDir,
        contextExtractor: productionLikeContextExtractor(w, config),
        isolationDiagnostics: isolationDiagnosticsFor(fixture!),
      );
      recorder.start();

      final variables = {'FEATURE': seededSpecPath, 'PROJECT': 'workflow-test-todo-app', 'BRANCH': 'main'};
      final run = await w.workflowService.start(definition, variables);
      final completionFuture = awaitWorkflowCompletion(w.eventBus, run.id);

      final finalStatus = await completionFuture.timeout(
        Duration(minutes: 60),
        onTimeout: () {
          fail('Workflow timed out after 60 minutes');
        },
      );

      await Future<void>.delayed(Duration(seconds: 2));
      await recorder.dispose();

      expectWorkflowFinalStatus(finalStatus: finalStatus, requireCompleted: requireCompleted, runId: run.id);

      // The reuse path skips `spec` (its gate is false) but still implements,
      // simplifies, and reviews against the reused spec.
      expectStepOrder(recorder, const ['implement', 'simplify-code', 'integrated-review']);
      expect(recorder.count('spec'), 0, reason: 'spec step must be skipped when reusing an existing FIS');
      expect(recorder.count('detect-spec-input'), 1, reason: 'detect-spec-input classifies the reused spec');

      final classifiedRun = await w.workflowService.get(run.id);
      expect(classifiedRun, isNotNull);
      final classifiedContext =
          (classifiedRun!.contextJson['data'] as Map?)?.cast<String, dynamic>() ?? classifiedRun.contextJson;
      expect(
        classifiedContext['spec_source'],
        'existing',
        reason: 'restored main-prompt instruction must flip spec_source to existing',
      );

      expectWorktreeRecorded(recorder, 'implement');
      expectNoMissingFisFallbacks(artifactDir);
      expectIsolationDiagnostics(artifactDir, fixture!);
      expectPublishFailureNotSilent(await w.workflowService.get(run.id), finalStatus);

      if (finalStatus == WorkflowRunStatus.completed) {
        final completedRun = await w.workflowService.get(run.id);
        expect(completedRun, isNotNull, reason: 'Completed run should be retrievable');
        expectPublishSuccess(completedRun!.contextJson);

        final publishBranch = _findPublishedBranch(fixtureDir, run.id);
        expect(publishBranch, isNotNull, reason: 'Integration branch should have been pushed to origin');
        final branch = publishBranch!;
        createdBranches.add(branch);
        await assertDiffTouchesExpectedFiles(
          projectDir: fixtureDir,
          headRef: 'main',
          publishedBranch: 'origin/$branch',
          bugAllowlist: bugFileAllowlist,
          activeBugs: const ['BUG-001'],
        );

        if (canCreateGitHubPr) {
          expectWorkflowCreatedPr(completedRun.contextJson, expectedBranch: branch);
        } else {
          expectWorkflowPublishedBranchOnly(completedRun.contextJson, expectedBranch: branch);
        }
      }
    },
    timeout: Timeout(Duration(minutes: 65)),
    tags: 'live-e2e',
  );

  test(
    'plan-and-implement e2e with real Codex harness and per-story worktrees',
    () async {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final w = await wireUp(
        outputTransformer: _forceSinglePlanReviewRemediationLoop(
          remediationPlan:
              'Synthetic test remediation: rerun one remediation iteration and confirm '
              'the batch remains clean after re-validation and re-review.',
          implementationSummary:
              'Synthetic test summary: both story implementations merged cleanly, '
              'but the E2E test is forcing one remediation iteration for coverage.',
          targetReviews: const {'plan-review', 'architecture-review'},
        ),
        prTitle: 'E2E plan-and-implement $timestamp',
      );
      final artifactDir = createPreservedArtifactDir('plan-and-implement-e2e');
      Logger('E2E.StepArtifacts').info('Preserving step artifacts in ${artifactDir.path}');

      final definition = w.registry.getByName('plan-and-implement')!;

      final recorder = WorkflowExecutionRecorder(
        w.eventBus,
        w.taskService,
        w.messageService,
        w.workflowService,
        w.kvService,
        definition,
        artifactDir: artifactDir,
        contextExtractor: productionLikeContextExtractor(w, config),
        isolationDiagnostics: isolationDiagnosticsFor(fixture!),
      );
      recorder.start();

      // Pre-authored plan seed: a committed plan.json + per-story FIS files that
      // discover-plan-state indexes into `plan` + `story_specs.items`, making the
      // `plan` step gate false → the authoring turn is skipped and the foreach
      // runs directly on the pre-made stories. The synthesize/existing/resume
      // branch matrix stays covered deterministically by the stubbed
      // workflow_builtin_plan_and_implement_test.dart; live plan authoring moves
      // to the plan step-isolation probe. Every seed file must be committed: the
      // workflow runs in a worktree off the base branch, so an uncommitted seed
      // is invisible there (the R6 root cause) and discovery would (correctly)
      // report no plan — mirrors the spec-and-implement reuse-seed commit above.
      const planDir = 'docs/specs/e2e-plan-and-implement';
      const prdPath = '$planDir/prd.md';
      const planJsonPath = '$planDir/plan.json';
      const story1FisPath = '$planDir/fis/s01-bug-002.md';
      const story2FisPath = '$planDir/fis/s02-bug-003.md';
      File(p.join(fixtureDir, prdPath))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '# Product Feature Document\n\n'
          'Fix BUG-002 and BUG-003 from docs/PRODUCT-BACKLOG.md (Known Defects section) '
          'as two independent, thin stories.\n\n'
          'Story 1: BUG-002 - due dates set in the edit dialog do not persist after save.\n'
          'Story 2: BUG-003 - quick-add todos have no default priority.\n\n'
          'Keep each story isolated to its own files; they must merge without conflict.\n',
        );
      File(p.join(fixtureDir, planJsonPath))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'stories': [
              {
                'id': 'S01',
                'title': 'Fix BUG-002 due-date persistence',
                'fis': 'fis/s01-bug-002.md',
                'dependsOn': <String>[],
                'status': 'spec-ready',
              },
              {
                'id': 'S02',
                'title': 'Fix BUG-003 default priority',
                'fis': 'fis/s02-bug-003.md',
                'dependsOn': <String>[],
                'status': 'spec-ready',
              },
            ],
          }),
        );
      File(p.join(fixtureDir, story1FisPath))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '# Fix BUG-002 — persist edited due dates\n\n'
          '## Feature Overview and Goal\n\n'
          '**Intent**: Close BUG-002 — a due date set in the edit dialog is lost '
          'after save. The update handler must read the submitted due-date field '
          'and persist it on the todo, and the edit dialog must pre-fill the '
          'current value.\n\n'
          '## Acceptance Scenarios\n\n'
          '- Editing a todo, setting a due date, and saving persists the due date '
          'so it is still present after the list re-renders.\n'
          '- The edit dialog pre-populates the existing due date when reopened.\n\n'
          '## Implementation Plan\n\n'
          '- In src/app/routes/todos.py, read the due-date form field in the update '
          'handler and store it on the todo.\n'
          '- In src/app/templates/app.html, bind the edit dialog\'s due-date input '
          'to the todo\'s current value.\n',
        );
      File(p.join(fixtureDir, story2FisPath))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '# Fix BUG-003 — default priority for quick-add todos\n\n'
          '## Feature Overview and Goal\n\n'
          '**Intent**: Close BUG-003 — todos created through quick-add have no '
          'default priority. Quick-add must assign the same default priority the '
          'full add form uses, and the list must render it.\n\n'
          '## Acceptance Scenarios\n\n'
          '- A todo created via quick-add is assigned the default priority.\n'
          '- The rendered list shows the priority for a quick-added todo.\n\n'
          '## Implementation Plan\n\n'
          '- In src/app/routes/todos.py, set the default priority when a quick-add '
          'todo is created.\n'
          '- In src/app/templates/partials/todo_list_content.html, render the todo '
          'priority so the default is visible.\n',
        );
      final addSeed = await Process.run('git', [
        'add',
        prdPath,
        planJsonPath,
        story1FisPath,
        story2FisPath,
      ], workingDirectory: fixtureDir);
      if (addSeed.exitCode != 0) {
        fail('Failed to stage plan-and-implement plan seed: ${addSeed.stderr}');
      }
      final commitSeed = await Process.run('git', [
        'commit',
        '-qm',
        'Add pre-authored plan-and-implement plan fixture',
      ], workingDirectory: fixtureDir);
      if (commitSeed.exitCode != 0) {
        fail('Failed to commit plan-and-implement plan seed: ${commitSeed.stderr}');
      }
      final variables = {
        'FEATURE': prdPath,
        'PROJECT': 'workflow-test-todo-app',
        'BRANCH': 'main',
        'MAX_PARALLEL': '2',
      };
      final run = await w.workflowService.start(definition, variables);
      final completionFuture = awaitWorkflowCompletion(w.eventBus, run.id);

      final finalStatus = await completionFuture.timeout(
        Duration(minutes: 75),
        onTimeout: () {
          fail('Workflow timed out after 75 minutes');
        },
      );

      await Future<void>.delayed(Duration(seconds: 2));
      await recorder.dispose();

      expectWorkflowFinalStatus(finalStatus: finalStatus, requireCompleted: requireCompleted, runId: run.id);

      final coreSteps = ['discover-plan-state', 'implement', 'simplify-code', 'review-story', 'remediate', 're-review'];
      expectStepOrderSubsequence(recorder.stepOrder, coreSteps);
      final remediateIndex = recorder.stepOrder.indexOf('remediate');
      expect(remediateIndex, isNonNegative, reason: 'remediate should run after forced review findings');
      for (final reviewStep in const ['plan-review', 'architecture-review']) {
        final reviewIndex = recorder.stepOrder.indexOf(reviewStep);
        expect(reviewIndex, isNonNegative, reason: '$reviewStep should run before remediation');
        expect(reviewIndex, lessThan(remediateIndex), reason: '$reviewStep should run before remediation');
      }

      expect(
        recorder.count('plan'),
        0,
        reason: 'plan step must be skipped when a pre-authored plan.json + story FIS are discovered',
      );
      expect(recorder.count('prd'), 0, reason: 'plan-and-implement requires a discovered PRD');
      expect(recorder.count('revise-prd'), 0, reason: 'plan-and-implement no longer revises PRDs');

      expect(
        recorder.count('implement'),
        greaterThanOrEqualTo(2),
        reason: 'implement should run at least twice (once per story)',
      );

      expect(
        recorder.count('review-story'),
        greaterThanOrEqualTo(2),
        reason: 'review-story should run at least twice (once per story)',
      );
      expect(
        recorder.count('plan-review'),
        inInclusiveRange(1, 2),
        reason: 'plan-review should run once, with at most one configured retry',
      );
      expect(
        recorder.count('architecture-review'),
        inInclusiveRange(1, 2),
        reason: 'architecture-review should run once, with at most one configured retry',
      );
      expect(recorder.count('remediate'), greaterThanOrEqualTo(1), reason: 'remediate should run at least once');
      expect(recorder.count('re-review'), greaterThanOrEqualTo(1), reason: 're-review should run at least once');
      final remediateInputs = recorder.tracesForStep('remediate').map((trace) => trace.inputs).toList(growable: false);
      expect(remediateInputs, isNotEmpty, reason: 'remediate should receive review findings input');
      // remediate consumes the aggregated report via prompt interpolation of
      // the canonical bare key ({{context.review_report_path}}); its inputs:
      // declaration carries only story_results. Assert the interpolation
      // source: the aggregate's canonical bare key in the run context.
      final finalRun = await w.workflowService.get(run.id);
      final finalContext = WorkflowContext.fromJson(finalRun?.contextJson ?? const <String, dynamic>{}).data;
      expect(
        (finalContext['review_report_path']?.toString().trim() ?? '').endsWith('.md'),
        isTrue,
        reason: 'aggregate should publish the canonical bare markdown review_report_path that remediate interpolates',
      );
      expect(
        remediateInputs.any(
          (inputs) => (inputs['architecture-review.review_report_path']?.toString().trim() ?? '').isNotEmpty,
        ),
        isFalse,
        reason: 'architecture findings should be represented in the aggregate review_report_path report',
      );

      expectWorktreeRecorded(recorder, 'implement');
      final worktreePathBySpec = <String, String>{};
      for (final trace in recorder.tracesForStep('implement')) {
        final specPath = (trace.configJson['requiredInputPath'] as String?)?.trim();
        final key = specPath == null || specPath.isEmpty ? trace.taskId : specPath;
        final worktreePath = trace.worktreeJson!['path'] as String;
        final previousPath = worktreePathBySpec[key];
        expect(
          previousPath == null || previousPath == worktreePath,
          isTrue,
          reason:
              'Retries for the same story/spec should reuse its per-story worktree. '
              'Spec $key used both $previousPath and $worktreePath.',
        );
        worktreePathBySpec[key] = worktreePath;
      }
      expectDistinctWorktreePaths(worktreePathBySpec.values.toList(growable: false));
      expectStepArtifactOutputs(artifactDir, 'plan-review', const {
        'plan-review.review_report_path',
        'plan-review.findings_count',
        'plan-review.gating_findings_count',
      });
      expectStepArtifactOutputs(artifactDir, 'architecture-review', const {
        'architecture-review.review_report_path',
        'architecture-review.findings_count',
        'architecture-review.gating_findings_count',
      });
      expectNoMissingFisFallbacks(artifactDir);
      expectIsolationDiagnostics(artifactDir, fixture!);

      expectPublishFailureNotSilent(await w.workflowService.get(run.id), finalStatus);

      if (finalStatus == WorkflowRunStatus.completed) {
        final completedRun = await w.workflowService.get(run.id);
        expect(completedRun, isNotNull, reason: 'Completed run should be retrievable');
        expectPublishSuccess(completedRun!.contextJson);

        final publishBranch = _findPublishedBranch(fixtureDir, run.id);
        expect(publishBranch, isNotNull, reason: 'Integration branch should have been pushed to origin');
        final branch = publishBranch!;
        createdBranches.add(branch);
        // The pre-authored plan seed (skipped `plan` step) must ride through to
        // the published integration branch so per-story worktrees inherited it.
        expectCommittedPaths(
          projectDir: fixtureDir,
          ref: 'origin/$branch',
          relativePaths: const [planJsonPath, story1FisPath, story2FisPath],
        );
        await assertDiffTouchesExpectedFiles(
          projectDir: fixtureDir,
          headRef: 'main',
          publishedBranch: 'origin/$branch',
          bugAllowlist: bugFileAllowlist,
          activeBugs: const ['BUG-002', 'BUG-003'],
        );

        if (canCreateGitHubPr) {
          expectWorkflowCreatedPr(completedRun.contextJson, expectedBranch: branch);
        } else {
          expectWorkflowPublishedBranchOnly(completedRun.contextJson, expectedBranch: branch);
        }
      }
    },
    timeout: Timeout(Duration(minutes: 80)),
    tags: 'live-e2e',
  );
}

String? _findPublishedBranch(String projectDir, String runId) {
  final sanitizedId = runId.replaceAll('-', '');
  final candidates = ['dartclaw/workflow/$sanitizedId/integration', 'dartclaw/workflow/$sanitizedId'];
  for (final branch in candidates) {
    final result = Process.runSync('git', ['rev-parse', '--verify', 'origin/$branch'], workingDirectory: projectDir);
    if (result.exitCode == 0) return branch;
  }
  return null;
}
