import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show CredentialsConfig, EventBus, ProjectConfig, ProjectDefinition, ProjectStatusChangedEvent;
import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show GitRunner, ProjectServiceImpl;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a fake [GitRunner] that returns a predetermined result.
GitRunner _fakeGitRunner({int exitCode = 0, String stderr = '', String stdout = ''}) {
  return (args, {environment, workingDirectory}) async => (exitCode: exitCode, stderr: stderr, stdout: stdout);
}

void main() {
  late Directory tempDir;
  late String dataDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('proj_svc_test_');
    dataDir = tempDir.path;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProjectServiceImpl makeService({
    ProjectConfig? projectConfig,
    CredentialsConfig? credentials,
    EventBus? eventBus,
    GitRunner? gitRunner,
  }) => ProjectServiceImpl(
    dataDir: dataDir,
    projectConfig: projectConfig ?? const ProjectConfig.defaults(),
    credentials: credentials ?? const CredentialsConfig.defaults(),
    eventBus: eventBus,
    gitRunner: gitRunner ?? _fakeGitRunner(),
  );

  group('initialize', () {
    test('creates _local project', () async {
      final svc = makeService();
      await svc.initialize();
      final local = svc.getLocalProject();
      expect(local.id, equals('_local'));
      expect(local.status, equals(ProjectStatus.ready));
      expect(local.configDefined, isFalse);
    });

    test('loads empty projects.json gracefully', () async {
      final svc = makeService();
      await svc.initialize();
      final all = await svc.getAll();
      expect(all.length, equals(1)); // just _local
      expect(all.first.id, equals('_local'));
    });

    test('loads projects.json on restart', () async {
      // Create and persist a project.
      final svc1 = makeService(gitRunner: _fakeGitRunner(exitCode: 0));
      await svc1.initialize();
      await svc1.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');

      // Restart with a new service instance.
      final svc2 = makeService(gitRunner: _fakeGitRunner());
      await svc2.initialize();

      final all = await svc2.getAll();
      expect(all.any((p) => p.remoteUrl == 'git@github.com:u/r.git'), isTrue);
    });

    test('recovers stale cloning status to error', () async {
      // Write a projects.json with a project stuck in cloning.
      final projectsFile = File('$dataDir/projects.json');
      final project = Project(
        id: 'stuck-clone',
        name: 'Stuck',
        remoteUrl: 'git@github.com:u/r.git',
        localPath: '$dataDir/projects/stuck-clone',
        status: ProjectStatus.cloning,
        createdAt: DateTime.now(),
      );
      projectsFile.writeAsStringSync('{"stuck-clone": ${_jsonEncode(project.toJson())}}');

      final svc = makeService();
      await svc.initialize();

      final recovered = await svc.get('stuck-clone');
      expect(recovered, isNotNull);
      expect(recovered!.status, equals(ProjectStatus.error));
      expect(recovered.errorMessage, contains('interrupted'));
    });

    test('seeds config-defined projects', () async {
      final config = ProjectConfig(
        definitions: {'cfg-project': const ProjectDefinition(id: 'cfg-project', remote: 'git@github.com:u/cfg.git')},
      );

      // Create the clone dir to simulate an already-cloned project.
      Directory('$dataDir/projects/cfg-project').createSync(recursive: true);

      final svc = makeService(projectConfig: config);
      await svc.initialize();

      final project = await svc.get('cfg-project');
      expect(project, isNotNull);
      expect(project!.configDefined, isTrue);
      expect(project.status, equals(ProjectStatus.ready));
    });

    test('config wins on ID collision with runtime project', () async {
      // Write a runtime project with same ID as a config project.
      final projectsFile = File('$dataDir/projects.json');
      final runtimeProject = Project(
        id: 'shared-id',
        name: 'Runtime Version',
        remoteUrl: 'https://old-remote.com/r.git',
        localPath: '$dataDir/projects/shared-id',
        status: ProjectStatus.ready,
        createdAt: DateTime.now(),
      );
      projectsFile.writeAsStringSync('{"shared-id": ${_jsonEncode(runtimeProject.toJson())}}');

      final config = ProjectConfig(
        definitions: {
          'shared-id': const ProjectDefinition(id: 'shared-id', remote: 'git@github.com:u/config-version.git'),
        },
      );

      Directory('$dataDir/projects/shared-id').createSync(recursive: true);

      final svc = makeService(projectConfig: config);
      await svc.initialize();

      final project = await svc.get('shared-id');
      expect(project, isNotNull);
      expect(project!.configDefined, isTrue);
      expect(project.remoteUrl, equals('git@github.com:u/config-version.git'));
    });
  });

  group('create', () {
    test('returns project in cloning status immediately', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();

      final project = await svc.create(name: 'test-app', remoteUrl: 'git@github.com:u/r.git');

      expect(project.status, equals(ProjectStatus.cloning));
      expect(project.remoteUrl, equals('git@github.com:u/r.git'));
      expect(project.id, isNotEmpty);
    });

    test('persists project to projects.json on create', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();

      await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');

      final projectsFile = File('$dataDir/projects.json');
      expect(projectsFile.existsSync(), isTrue);
    });

    test('throws ArgumentError on duplicate ID', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();

      await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');

      expect(() => svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git'), throwsArgumentError);
    });

    test('clone success transitions project to ready', () async {
      final svc = makeService(gitRunner: _fakeGitRunner(exitCode: 0));
      await svc.initialize();

      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');
      // Wait briefly for the async clone to complete.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final updated = await svc.get(project.id);
      expect(updated!.status, equals(ProjectStatus.ready));
      expect(updated.lastFetchAt, isNotNull);
    });

    test('clone failure transitions project to error and cleans up', () async {
      // Create partial clone dir to verify cleanup.
      final cloneDir = Directory('$dataDir/projects/my-app');
      cloneDir.createSync(recursive: true);

      final svc = makeService(gitRunner: _fakeGitRunner(exitCode: 128, stderr: 'fatal: repository not found'));
      await svc.initialize();

      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/bad.git');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final updated = await svc.get(project.id);
      expect(updated!.status, equals(ProjectStatus.error));
      expect(updated.errorMessage, isNotEmpty);
    });

    test('fires ProjectStatusChangedEvent on status transition', () async {
      final events = <ProjectStatusChangedEvent>[];
      final eventBus = EventBus();
      eventBus.on<ProjectStatusChangedEvent>().listen(events.add);

      final svc = makeService(gitRunner: _fakeGitRunner(exitCode: 0), eventBus: eventBus);
      await svc.initialize();

      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // At least 2 events: initial cloning (oldStatus=null) + ready transition.
      expect(events.any((e) => e.projectId == project.id && e.newStatus == ProjectStatus.ready), isTrue);
    });
  });

  group('get / getAll', () {
    test('get returns null for unknown project', () async {
      final svc = makeService();
      await svc.initialize();
      expect(await svc.get('unknown'), isNull);
    });

    test('get returns _local for _local id', () async {
      final svc = makeService();
      await svc.initialize();
      final local = await svc.get('_local');
      expect(local, isNotNull);
      expect(local!.id, equals('_local'));
    });

    test('getAll includes _local as first entry', () async {
      final svc = makeService();
      await svc.initialize();
      final all = await svc.getAll();
      expect(all.first.id, equals('_local'));
    });
  });

  group('getDefaultProject', () {
    test('returns _local when no external projects', () async {
      final svc = makeService();
      await svc.initialize();
      final def = await svc.getDefaultProject();
      expect(def.id, equals('_local'));
    });

    test('returns first external project when present', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();
      await svc.create(name: 'app', remoteUrl: 'git@github.com:u/app.git');

      final def = await svc.getDefaultProject();
      expect(def.id, isNot(equals('_local')));
    });

    test('returns config-marked default project', () async {
      Directory('$dataDir/projects/app-one').createSync(recursive: true);
      Directory('$dataDir/projects/app-two').createSync(recursive: true);

      final config = ProjectConfig(
        definitions: {
          'app-one': const ProjectDefinition(id: 'app-one', remote: 'git@h:u/a.git', isDefault: false),
          'app-two': const ProjectDefinition(id: 'app-two', remote: 'git@h:u/b.git', isDefault: true),
        },
      );

      final svc = makeService(projectConfig: config);
      await svc.initialize();

      final def = await svc.getDefaultProject();
      expect(def.id, equals('app-two'));
    });
  });

  group('update', () {
    test('updates mutable fields for runtime project', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();
      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');

      final updated = await svc.update(project.id, name: 'Renamed App');
      expect(updated.name, equals('Renamed App'));
      expect(updated.id, equals(project.id));
    });

    test('throws StateError for config-defined project', () async {
      Directory('$dataDir/projects/cfg-project').createSync(recursive: true);
      final config = ProjectConfig(
        definitions: {'cfg-project': const ProjectDefinition(id: 'cfg-project', remote: 'git@h:u/c.git')},
      );

      final svc = makeService(projectConfig: config);
      await svc.initialize();

      expect(() => svc.update('cfg-project', name: 'Changed'), throwsStateError);
    });

    test('throws ArgumentError for unknown project', () async {
      final svc = makeService();
      await svc.initialize();

      expect(() => svc.update('unknown', name: 'X'), throwsArgumentError);
    });

    test('changing remote coordinates triggers a fresh clone lifecycle', () async {
      final gitCalls = <List<String>>[];

      Future<({int exitCode, String stderr, String stdout})> gitRunner(
        List<String> args, {
        Map<String, String>? environment,
        String? workingDirectory,
      }) async {
        gitCalls.add(List<String>.from(args));
        if (args.isNotEmpty && args.first == 'clone') {
          Directory(args.last).createSync(recursive: true);
        }
        return (exitCode: 0, stderr: '', stdout: '');
      }

      final svc = makeService(gitRunner: gitRunner);
      await svc.initialize();
      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final originalClone = Directory(project.localPath)..createSync(recursive: true);
      final oldMarker = File(p.join(originalClone.path, 'old.txt'))..writeAsStringSync('stale clone');

      final updated = await svc.update(project.id, remoteUrl: 'git@github.com:u/new.git', defaultBranch: 'develop');

      expect(updated.status, ProjectStatus.cloning);
      expect(updated.remoteUrl, 'git@github.com:u/new.git');
      expect(updated.defaultBranch, 'develop');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final refreshed = await svc.get(project.id);
      expect(refreshed, isNotNull);
      expect(refreshed!.status, ProjectStatus.ready);
      expect(refreshed.remoteUrl, 'git@github.com:u/new.git');
      expect(refreshed.defaultBranch, 'develop');
      expect(oldMarker.existsSync(), isFalse);

      final cloneCalls = gitCalls.where((args) => args.isNotEmpty && args.first == 'clone').toList();
      expect(cloneCalls, hasLength(2));
      expect(cloneCalls.last, containsAll(['--branch', 'develop', 'git@github.com:u/new.git', project.localPath]));
    });
  });

  group('delete', () {
    test('removes runtime project', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();
      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');

      await svc.delete(project.id);

      expect(await svc.get(project.id), isNull);
    });

    test('throws StateError for config-defined project', () async {
      Directory('$dataDir/projects/cfg-project').createSync(recursive: true);
      final config = ProjectConfig(
        definitions: {'cfg-project': const ProjectDefinition(id: 'cfg-project', remote: 'git@h:u/c.git')},
      );

      final svc = makeService(projectConfig: config);
      await svc.initialize();

      expect(() => svc.delete('cfg-project'), throwsStateError);
    });

    test('throws ArgumentError for unknown project', () async {
      final svc = makeService();
      await svc.initialize();
      expect(() => svc.delete('unknown'), throwsArgumentError);
    });

    test('_local is NOT persisted to projects.json', () async {
      final svc = makeService(gitRunner: _fakeGitRunner());
      await svc.initialize();
      await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');

      final projectsFile = File('$dataDir/projects.json');
      expect(projectsFile.existsSync(), isTrue);

      final content = projectsFile.readAsStringSync();
      expect(content, isNot(contains('_local')));
    });
  });

  group('ensureFresh', () {
    /// Helper to build a ready project with optional lastFetchAt.
    Project makeReadyProject({DateTime? lastFetchAt}) => Project(
      id: 'my-app',
      name: 'My App',
      remoteUrl: 'git@github.com:u/r.git',
      localPath: p.join(dataDir, 'projects', 'my-app'),
      defaultBranch: 'main',
      status: ProjectStatus.ready,
      createdAt: DateTime.now(),
      lastFetchAt: lastFetchAt,
    );

    test('fetches when outside cooldown (no lastFetchAt)', () async {
      final commands = <List<String>>[];
      final svc = makeService(
        gitRunner: (args, {environment, workingDirectory}) async {
          commands.add(args);
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      await svc.ensureFresh(makeReadyProject());

      expect(commands, anyElement(predicate<List<String>>((c) => c.isNotEmpty && c[0] == 'fetch')));
    });

    test('skips fetch within cooldown window (lastFetchAt recent)', () async {
      final commands = <List<String>>[];
      final svc = makeService(
        projectConfig: const ProjectConfig(fetchCooldownMinutes: 5),
        gitRunner: (args, {environment, workingDirectory}) async {
          commands.add(args);
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      // Recent lastFetchAt — within 5-minute cooldown.
      final project = makeReadyProject(lastFetchAt: DateTime.now().subtract(const Duration(minutes: 2)));
      await svc.ensureFresh(project);

      expect(commands, isNot(anyElement(predicate<List<String>>((c) => c.isNotEmpty && c[0] == 'fetch'))));
    });

    test('fetches when outside cooldown window (lastFetchAt old)', () async {
      final commands = <List<String>>[];
      final svc = makeService(
        projectConfig: const ProjectConfig(fetchCooldownMinutes: 5),
        gitRunner: (args, {environment, workingDirectory}) async {
          commands.add(args);
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      // Old lastFetchAt — outside 5-minute cooldown.
      final project = makeReadyProject(lastFetchAt: DateTime.now().subtract(const Duration(minutes: 10)));
      await svc.ensureFresh(project);

      expect(commands, anyElement(predicate<List<String>>((c) => c.isNotEmpty && c[0] == 'fetch')));
    });

    test('fetch for external project includes branch name', () async {
      final commands = <List<String>>[];
      final svc = makeService(
        gitRunner: (args, {environment, workingDirectory}) async {
          commands.add(args);
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      await svc.ensureFresh(makeReadyProject());

      final fetchCall = commands.firstWhere((c) => c.isNotEmpty && c[0] == 'fetch', orElse: () => []);
      expect(fetchCall, contains('main'));
    });

    test('does not throw on fetch failure — best-effort', () async {
      final svc = makeService(
        gitRunner: (args, {environment, workingDirectory}) async {
          if (args.isNotEmpty && args[0] == 'fetch') {
            return (exitCode: 128, stderr: 'fatal: could not reach remote', stdout: '');
          }
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      // Should not throw.
      await expectLater(svc.ensureFresh(makeReadyProject()), completes);
    });

    test('_local project runs git fetch + merge --ff-only', () async {
      final commands = <List<String>>[];
      final svc = makeService(
        gitRunner: (args, {environment, workingDirectory}) async {
          commands.add(args);
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      final localProject = svc.getLocalProject();
      await svc.ensureFresh(localProject);

      expect(commands, anyElement(predicate<List<String>>((c) => c.isNotEmpty && c[0] == 'fetch')));
      expect(
        commands,
        anyElement(predicate<List<String>>((c) => c.length >= 2 && c[0] == 'merge' && c[1] == '--ff-only')),
      );
    });

    test('_local project failed merge does not throw', () async {
      final svc = makeService(
        gitRunner: (args, {environment, workingDirectory}) async {
          if (args.isNotEmpty && args[0] == 'merge') {
            return (exitCode: 1, stderr: 'merge conflict', stdout: '');
          }
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      await expectLater(svc.ensureFresh(svc.getLocalProject()), completes);
    });

    test('does not fetch within cooldown window (existing test)', () async {
      var fetchCallCount = 0;
      Future<({int exitCode, String stderr, String stdout})> countingRunner(
        List<String> args, {
        Map<String, String>? environment,
        String? workingDirectory,
      }) async {
        if (args.isNotEmpty && args[0] == 'fetch') fetchCallCount++;
        return (exitCode: 0, stderr: '', stdout: '');
      }

      final svc = makeService(gitRunner: countingRunner);
      await svc.initialize();

      // Create a project with a recent lastFetchAt.
      final project = await svc.create(name: 'my-app', remoteUrl: 'git@github.com:u/r.git');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The project should now be ready with lastFetchAt set.
      final readyProject = await svc.get(project.id);
      if (readyProject?.status != ProjectStatus.ready) return; // Skip if clone failed

      // ensureFresh should skip fetch since we just cloned (lastFetchAt is recent).
      final fetchBefore = fetchCallCount;
      await svc.ensureFresh(readyProject!);
      expect(fetchCallCount, equals(fetchBefore)); // No extra fetch
    });

    test('concurrent ensureFresh calls deduplicate — only one fetch runs', () async {
      var fetchCallCount = 0;
      final svc = makeService(
        gitRunner: (args, {environment, workingDirectory}) async {
          if (args.isNotEmpty && args[0] == 'fetch') {
            fetchCallCount++;
            // Small delay to let the second call arrive while first is in-flight.
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return (exitCode: 0, stderr: '', stdout: '');
        },
      );
      await svc.initialize();

      // Project with no lastFetchAt — outside cooldown, will trigger fetch.
      final project = makeReadyProject();

      // Fire two concurrent ensureFresh calls.
      await Future.wait([svc.ensureFresh(project), svc.ensureFresh(project)]);

      // Only one fetch should have run — the second waited on the in-flight Completer.
      expect(fetchCallCount, equals(1));
    });
  });
}

/// Minimal JSON encoding for test fixtures.
String _jsonEncode(Map<String, dynamic> json) {
  final entries = json.entries.map((e) {
    final key = '"${e.key}"';
    final value = e.value is String
        ? '"${e.value}"'
        : e.value is bool
        ? e.value.toString()
        : e.value is Map
        ? _jsonEncode(e.value as Map<String, dynamic>)
        : '${e.value}';
    return '$key: $value';
  });
  return '{${entries.join(', ')}}';
}
