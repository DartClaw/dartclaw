import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/container/security_profile.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late String root;
  late EventBus eventBus;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() {
    // Canonical from the start: macOS temp dirs sit behind `/var` -> `/private/var`.
    root = Directory.systemTemp.createTempSync('security_wiring_data_dir_mount_').resolveSymbolicLinksSync();
    eventBus = EventBus();
    records = [];
    logSubscription = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await logSubscription.cancel();
    await eventBus.dispose();
    Directory(root).deleteSync(recursive: true);
  });

  String dir(String relative) => (Directory(p.join(root, relative))..createSync(recursive: true)).path;

  SecurityWiring wiring({required String dataDir, required String? localRepositoryDir, ProjectConfig? projects}) =>
      SecurityWiring(
        config: DartclawConfig(
          server: ServerConfig(dataDir: dataDir),
          projects: projects ?? const ProjectConfig(),
        ),
        dataDir: dataDir,
        localRepositoryDir: localRepositoryDir,
        eventBus: eventBus,
        exitFn: _unexpectedExit,
        auditLogger: GuardAuditLogger(dataDir: dataDir),
      );

  List<LogRecord> wiringRecords() => records.where((record) => record.loggerName == 'SecurityWiring').toList();

  test('a runtime directory equal to the data directory is not mounted', () {
    final dataDir = dir('data');
    File(p.join(dataDir, 'gateway_token')).writeAsStringSync('gateway-secret');
    File(p.join(dir('data/credentials/claude'), 'setup-token.json')).writeAsStringSync('{}');
    final security = wiring(dataDir: dataDir, localRepositoryDir: dataDir);

    final plan = security.workspaceMountPlan();
    security.workspaceMountPlan();

    expect(plan.mounts, [
      '${p.join(dataDir, 'workspace')}:/workspace:rw',
      '${p.join(dataDir, 'projects')}:/projects:ro',
      SecurityProfile.packageCachePath,
    ]);
    expect(plan.workingDir, '/workspace');
    for (final spec in plan.mounts) {
      final parts = spec.split(':');
      if (parts.length < 2) continue;
      final source = canonicalizePathWithExistingAncestors(parts[0]);
      expect(p.equals(source, dataDir) || p.isWithin(source, dataDir), isFalse, reason: spec);
    }
    final logged = wiringRecords();
    expect(logged, hasLength(1), reason: 'the owner set is composed once per instance');
    expect(logged.single.level, Level.INFO);
    expect(logged.single.message, allOf(contains(dataDir), contains('data directory')));
  });

  test('a runtime with no local repository mounts nothing at /project', () {
    final dataDir = dir('data');
    final workspace = dir('data/workspace');
    final security = wiring(dataDir: dataDir, localRepositoryDir: null);

    final plan = security.workspaceMountPlan();

    expect(plan.mounts, [
      '$workspace:/workspace:rw',
      '${p.join(dataDir, 'projects')}:/projects:ro',
      SecurityProfile.packageCachePath,
    ]);
    expect(plan.workingDir, '/workspace');
  });

  test('a data directory inside the runtime directory is masked at /project', () {
    final repo = dir('repo');
    final dataDir = dir('repo/.dartclaw-example');
    final security = wiring(dataDir: dataDir, localRepositoryDir: repo);

    final plan = security.workspaceMountPlan();

    expect(plan.mounts, [
      '${p.join(dataDir, 'workspace')}:/workspace:rw',
      '${p.join(dataDir, 'projects')}:/projects:ro',
      SecurityProfile.packageCachePath,
      '$repo:/project:ro',
      '/project/.dartclaw-example',
    ]);
    expect(plan.workingDir, '/project');
    final logged = wiringRecords();
    expect(logged, hasLength(1));
    expect(logged.single.level, Level.INFO);
    expect(logged.single.message, allOf(contains(repo), contains('/project/.dartclaw-example')));
  });

  test("local-path projects and a named agent's execution directory follow the data directory rule", () {
    final runtimeCwd = dir('repo');
    final outer = dir('outer');
    final dataDir = dir('outer/state');
    final agentWorkspace = dir('outer/state/agents/researcher/workspace');
    final security = wiring(
      dataDir: dataDir,
      localRepositoryDir: runtimeCwd,
      projects: ProjectConfig(
        definitions: {
          'same': ProjectDefinition(id: 'same', localPath: dataDir),
          'outer': ProjectDefinition(id: 'outer', localPath: outer),
        },
      ),
    );

    final owner = security.workspaceMountPlan();

    expect(owner.mounts, [
      '${p.join(dataDir, 'workspace')}:/workspace:rw',
      '${p.join(dataDir, 'projects')}:/projects:ro',
      SecurityProfile.packageCachePath,
      '$runtimeCwd:/project:ro',
      '$outer:/projects/outer:ro',
      '/projects/outer/state',
    ]);
    expect(owner.workingDir, '/project');
    final ownerRecords = wiringRecords();
    expect(ownerRecords.map((record) => record.level), everyElement(Level.INFO));
    expect(ownerRecords.map((record) => record.message), [
      allOf(contains(dataDir), contains('/projects/same'), contains('data directory')),
      allOf(contains(outer), contains('/projects/outer/state')),
    ]);

    records.clear();
    final agent = security.workspaceMountPlan(
      workspaceDir: agentWorkspace,
      executionDir: dataDir,
      useOwnerWorkspace: false,
    );

    expect(agent.mounts, ['$agentWorkspace:/workspace:rw', SecurityProfile.packageCachePath]);
    expect(agent.workingDir, '/workspace');
    final agentRecords = wiringRecords();
    expect(agentRecords, hasLength(1), reason: 'an execution directory reason logs at acquisition');
    expect(agentRecords.single.level, Level.INFO);
    expect(agentRecords.single.message, allOf(contains(dataDir), contains('/project'), contains('data directory')));
  });
}
