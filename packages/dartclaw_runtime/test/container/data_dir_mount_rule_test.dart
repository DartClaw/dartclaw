@TestOn('posix')
library;

import 'dart:io';

import 'package:dartclaw_runtime/src/container/data_dir_mount_rule.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late String root;

  setUp(() {
    // Canonical from the start: macOS temp dirs sit behind `/var` -> `/private/var`.
    root = Directory.systemTemp.createTempSync('data_dir_mount_rule_test_').resolveSymbolicLinksSync();
  });
  tearDown(() => Directory(root).deleteSync(recursive: true));

  String dir(String relative) => (Directory(p.join(root, relative))..createSync(recursive: true)).path;
  String link(String relative, String target) {
    Directory(p.dirname(p.join(root, relative))).createSync(recursive: true);
    return (Link(p.join(root, relative))..createSync(target)).path;
  }

  test('a source inside the data directory, directly or through a symlink, yields no mount', () {
    final dataDir = dir('data');
    File(p.join(dataDir, 'gateway_token')).writeAsStringSync('secret');
    final logs = dir('data/logs');
    final dataDirLink = link('data-link', dataDir);
    final logsLink = link('outside/logs-link', logs);

    for (final dataDirSpelling in [dataDir, dataDirLink]) {
      for (final source in [dataDir, logs, logsLink]) {
        final mount = operatorMount(source: source, target: '/project', dataDir: dataDirSpelling);

        expect(mount.specs, isEmpty, reason: '$source with data directory $dataDirSpelling');
        expect(mount.reason, allOf(contains(source), contains('data directory')));
      }
    }
  });

  test('a source containing the data directory masks it with an anonymous volume', () {
    final repo = dir('repo');
    final dataDir = dir('repo/a/data');
    final repoLink = link('repo-link', repo);

    for (final source in [repo, repoLink]) {
      final mount = operatorMount(source: source, target: '/projects/demo', dataDir: dataDir);

      expect(mount.specs, ['$source:/projects/demo:ro', '/projects/demo/a/data']);
      expect(mount.reason, allOf(contains(source), contains('/projects/demo/a/data')));
    }
  });

  test('an unrelated source or a DartClaw-owned project directory mounts unchanged', () {
    final dataDir = dir('data');
    final workspaceDir = dir('data/workspace');
    final clonesDir = dir('data/projects');
    final agentWorkspace = dir('data/agents/researcher/workspace');

    for (final source in [
      dir('elsewhere/repo'),
      dir('data/projects/demo'),
      dir('data/workspace/.dartclaw/worktrees/task-1'),
      agentWorkspace,
    ]) {
      final mount = operatorMount(
        source: source,
        target: '/project',
        dataDir: dataDir,
        ownedRoots: [workspaceDir, clonesDir, agentWorkspace],
      );

      expect(mount.specs, ['$source:/project:ro']);
      expect(mount.reason, isNull);
    }
  });
}
