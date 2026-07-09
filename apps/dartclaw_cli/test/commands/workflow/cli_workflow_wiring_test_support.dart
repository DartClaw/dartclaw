import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowCliProcessStarter;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProcessRunner,
        ProviderAuthPreflight,
        SkillIntrospector,
        WorkflowDefinition,
        WorkflowStep,
        WorkflowTaskType,
        WorkflowVariable;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

HarnessFactory harnessFactoryFor(AgentHarness Function() builder) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => builder());
  return factory;
}

HarnessFactory capturingHarnessFactory(
  Map<String, List<HarnessFactoryConfig>> capturedByProvider,
  Iterable<String> providerIds,
) {
  final factory = HarnessFactory();
  for (final providerId in providerIds) {
    factory.register(providerId, (config) {
      // Ignore capability-probe constructions (cwd:'/', no spawn) — e.g.
      // `probeContinuityProviders` during pre-harness registry wiring — so
      // captures reflect only real runner spawns.
      if (config.cwd != '/') {
        capturedByProvider.putIfAbsent(providerId, () => <HarnessFactoryConfig>[]).add(config);
      }
      return FakeAgentHarness();
    });
  }
  return factory;
}

/// A [FakeAgentHarness] whose [start] throws — stands in for a provider whose
/// real harness would throw from `_verifyAuth`. Used to prove the pre-harness
/// phase never reaches `harness.start()`.
class ThrowOnStartHarness extends FakeAgentHarness {
  @override
  Future<void> start() async {
    await super.start();
    throw StateError('harness start blew up (logged-out provider)');
  }
}

/// A factory registering [ThrowOnStartHarness] for every id in [providerIds].
HarnessFactory throwOnStartHarnessFactory(Iterable<String> providerIds) {
  final factory = HarnessFactory();
  for (final providerId in providerIds) {
    factory.register(providerId, (_) => ThrowOnStartHarness());
  }
  return factory;
}

ProcessResult runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
  return result;
}

Future<void> waitFor(bool Function() predicate, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class CliWorkflowWiringFixture {
  CliWorkflowWiringFixture(this.tempDir);

  final Directory tempDir;

  DartclawConfig config({
    AgentConfig agent = const AgentConfig(provider: 'claude'),
    ProvidersConfig? providers,
    CredentialsConfig credentials = const CredentialsConfig(),
    ProjectConfig projects = const ProjectConfig(),
    WorkflowConfig workflow = const WorkflowConfig(),
    TaskConfig tasks = const TaskConfig(),
  }) {
    return DartclawConfig(
      agent: agent,
      providers:
          providers ??
          ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
      credentials: credentials,
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      projects: projects,
      workflow: workflow,
      tasks: tasks,
    );
  }

  CliWorkflowWiring wiring(
    DartclawConfig config, {
    HarnessFactory? harnessFactory,
    SkillIntrospector? skillIntrospector,
    ProviderAuthPreflight? providerAuthPreflight,
    String? runtimeCwd,
    bool runWorkflowSkillsBootstrap = false,
    bool autoDispose = true,
    Map<String, String>? environment,
    ProcessRunner? skillProvisionerProcessRunner,
    WorkflowCliProcessStarter? workflowCliProcessStarter,
  }) {
    final wired = CliWorkflowWiring(
      config: config,
      dataDir: tempDir.path,
      runWorkflowSkillsBootstrap: runWorkflowSkillsBootstrap,
      environment: environment ?? {'HOME': p.join(tempDir.path, 'fake-home')},
      runtimeCwd: runtimeCwd,
      harnessFactory: harnessFactory ?? harnessFactoryFor(() => FakeAgentHarness()),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      skillIntrospector: skillIntrospector,
      // Default to an authenticated auth preflight so wiring tests never spawn a
      // real provider CLI; tests that exercise the gate inject their own.
      providerAuthPreflight: providerAuthPreflight ?? FakeProviderAuthPreflight(),
      skillProvisionerProcessRunner: skillProvisionerProcessRunner,
      workflowCliProcessStarter: workflowCliProcessStarter,
    );
    if (autoDispose) {
      addTearDown(wired.dispose);
    }
    return wired;
  }

  Future<T> withWiredCurrentDirectory<T>(
    Directory currentDirectory,
    DartclawConfig config, {
    String? runtimeCwd,
    HarnessFactory? harnessFactory,
    WorkflowCliProcessStarter? workflowCliProcessStarter,
    required Future<T> Function(CliWorkflowWiring wiring) body,
  }) async {
    final savedCwd = Directory.current;
    Directory.current = currentDirectory;
    CliWorkflowWiring? wired;
    try {
      wired = wiring(
        config,
        runtimeCwd: runtimeCwd,
        harnessFactory: harnessFactory,
        workflowCliProcessStarter: workflowCliProcessStarter,
        autoDispose: false,
      );
      await wired.wire();
      return await body(wired);
    } finally {
      if (wired != null) {
        await wired.dispose();
      }
      Directory.current = savedCwd;
    }
  }

  Directory seedGitRepo(String name, {String readme = 'hello\n'}) {
    final repoDir = Directory(p.join(tempDir.path, name))..createSync(recursive: true);
    runGit(repoDir.path, ['init', '-b', 'main']);
    runGit(repoDir.path, ['config', 'user.name', 'Test User']);
    runGit(repoDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync(readme);
    runGit(repoDir.path, ['add', 'README.md']);
    runGit(repoDir.path, ['commit', '-m', 'initial']);
    return repoDir;
  }
}

WorkflowDefinition branchGuardDefinition({
  String name = 'branch-guard',
  bool projectRequired = true,
  bool branchRequired = false,
}) {
  return WorkflowDefinition(
    name: name,
    description: 'Checks local-path branch safety',
    variables: {
      'PROJECT': WorkflowVariable(required: projectRequired, description: 'Target project'),
      'BRANCH': WorkflowVariable(required: branchRequired, description: 'Requested branch'),
    },
    steps: const [
      WorkflowStep(id: 'check', name: 'Check', taskType: WorkflowTaskType.agent, prompts: ['Say OK']),
    ],
  );
}

void seedAndthenSrc(String srcDir, {required String sha}) {
  Directory(srcDir).createSync(recursive: true);
  Directory(p.join(srcDir, '.git')).createSync(recursive: true);
  final scriptDir = Directory(p.join(srcDir, 'scripts'))..createSync(recursive: true);
  File(p.join(scriptDir.path, 'install-skills.sh')).writeAsStringSync('#!/bin/sh\nexit 0\n');
  File(p.join(srcDir, '.git', 'HEAD_SHA')).writeAsStringSync(sha);
}

List<String> unexpectedDataDirSkillEntries(String dataDir) {
  final allowed = {
    'dartclaw-discover-andthen-spec',
    'dartclaw-discover-andthen-plan',
    'dartclaw-validate-workflow',
    'dartclaw-merge-resolve',
  };
  final roots = [Directory(p.join(dataDir, '.agents', 'skills')), Directory(p.join(dataDir, '.claude', 'skills'))];
  return [
    for (final root in roots)
      if (root.existsSync())
        for (final entity in root.listSync(followLinks: false))
          if (entity is Directory && !allowed.contains(p.basename(entity.path))) entity.path,
  ];
}

Directory seedDcNativeSkillsSource(String sourceDir) {
  final dir = Directory(sourceDir)..createSync(recursive: true);
  const skillNames = [
    'dartclaw-discover-andthen-spec',
    'dartclaw-discover-andthen-plan',
    'dartclaw-validate-workflow',
    'dartclaw-merge-resolve',
  ];
  for (final name in skillNames) {
    File(p.join(dir.path, name, 'SKILL.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('---\nname: $name\n---\n\n# $name\n');
  }
  File(p.join(dir.path, 'dartclaw-native-skills.txt')).writeAsStringSync('${skillNames.join('\n')}\n');
  return dir;
}

class FakeProvisionerProcessRunner {
  final List<({String executable, List<String> arguments, String? workingDirectory})> calls = [];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));

    if (executable == 'git' && arguments.contains('rev-parse')) {
      final cIndex = arguments.indexOf('-C');
      final srcDir = cIndex >= 0 && cIndex + 1 < arguments.length ? arguments[cIndex + 1] : null;
      final shaFile = srcDir == null ? null : File(p.join(srcDir, '.git', 'HEAD_SHA'));
      return ProcessResult(0, 0, '${shaFile?.readAsStringSync().trim() ?? 'standalone-head'}\n', '');
    }
    if (executable == 'git') {
      return ProcessResult(0, 0, '', '');
    }
    if (executable.endsWith('install-skills.sh')) {
      String? skillsDir;
      String? codexAgentsDir;
      String? claudeSkillsDir;
      String? claudeAgentsDir;
      for (var i = 0; i < arguments.length - 1; i++) {
        switch (arguments[i]) {
          case '--skills-dir':
            skillsDir = arguments[i + 1];
          case '--codex-agents-dir':
            codexAgentsDir = arguments[i + 1];
          case '--claude-skills-dir':
            claudeSkillsDir = arguments[i + 1];
          case '--claude-agents-dir':
            claudeAgentsDir = arguments[i + 1];
        }
      }
      if (arguments.contains('--claude-user')) {
        final home = environment?['HOME'];
        if (home == null || home.isEmpty) {
          return ProcessResult(0, 2, '', 'HOME is required for --claude-user');
        }
        skillsDir ??= p.join(home, '.agents', 'skills');
        codexAgentsDir ??= p.join(home, '.codex', 'agents');
        claudeSkillsDir ??= p.join(home, '.claude', 'skills');
        claudeAgentsDir ??= p.join(home, '.claude', 'agents');
      }
      for (final dir in [skillsDir, codexAgentsDir, claudeSkillsDir, claudeAgentsDir].whereType<String>()) {
        Directory(dir).createSync(recursive: true);
      }
      for (final dir in [skillsDir, claudeSkillsDir].whereType<String>()) {
        for (final name in shippedDartclawSkillRefs) {
          File(p.join(dir, name, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('---\nname: $name\ndescription: fake $name\n---\n# $name\n');
        }
      }
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }
}

const shippedDartclawSkillRefs = <String>[
  'andthen:prd',
  'andthen:spec',
  'andthen:plan',
  'andthen:exec-spec',
  'andthen:architecture',
  'andthen:review',
  'andthen:quick-review',
  'andthen:remediate-findings',
  'andthen:simplify-code',
];

void seedProviderAndThenSkills(String home) {
  final claudeRoot = p.join(home, '.claude', 'skills');
  for (final name in shippedDartclawSkillRefs) {
    final dir = Directory(p.join(claudeRoot, name))..createSync(recursive: true);
    File(p.join(dir.path, 'SKILL.md')).writeAsStringSync('---\nname: $name\ndescription: fake $name\n---\n# $name\n');
  }
}
