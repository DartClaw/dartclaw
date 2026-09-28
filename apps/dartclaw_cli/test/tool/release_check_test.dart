import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final root = Platform.environment['DARTCLAW_REPO_ROOT'] ?? Platform.environment['PWD'] ?? Directory.current.path;
  final repo = _findRoot(root);
  late Directory fixture;
  late Map<String, String> environment;

  ProcessResult run(List<String> args) => Process.runSync(
    Platform.resolvedExecutable,
    ['dev/tools/release_check.dart', '--version', '0.27.0', ...args],
    workingDirectory: fixture.path,
    environment: environment,
  );

  void git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: fixture.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  File file(String name, [String? contents]) {
    final result = File(p.join(fixture.path, name));
    result.parent.createSync(recursive: true);
    if (contents != null) result.writeAsStringSync(contents);
    return result;
  }

  List<File> receipts(String gate) =>
      Directory(p.join(fixture.path, '.agent_temp/releases/0.27.0', gate))
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'receipt.json')
          .toList();

  setUp(() {
    final temp = Directory(p.join(repo, '.agent_temp'))..createSync(recursive: true);
    fixture = temp.createTempSync('release-check-test-');
    file('dev/tools/release_check.dart')
        .writeAsStringSync(File(p.join(repo, 'dev/tools/release_check.dart')).readAsStringSync());
    file('.gitignore', '.agent_temp/\n**/generated/\n');
    file('pubspec.lock', 'fixture\n');
    file('dev/tools/mascot_favicon/pubspec.lock', 'fixture\n');
    for (final script in ['check_versions', 'test_workspace', 'postgres_contract', 'build']) {
      file('dev/tools/$script.sh', '#!/bin/sh\nexec fake-gate $script\n');
    }
    file('dev/tools/fitness/run_all.sh', '#!/bin/sh\nexec fake-gate fitness\n');
    file('.agent_temp/bin/fake-gate', r'''#!/bin/sh
echo "$*" >> .agent_temp/calls
if [ -f .agent_temp/fail ]; then echo 'injected failure' >&2; exit 7; fi
if [ -f .agent_temp/drift ]; then echo drift >> pubspec.lock; fi
echo 'fixture gate passed'
''');
    file('.agent_temp/bin/dart', r'''#!/bin/sh
if [ "$1" = '--version' ]; then echo 'Dart fixture SDK'; exit 0; fi
if [ "$1" = run ] && [ "$2" = dev/tools/embed_assets.dart ]; then
  mkdir -p packages/dartclaw_runtime/lib/src/generated packages/dartclaw_workflow/lib/src/generated
  echo fixture > packages/dartclaw_runtime/lib/src/generated/embedded_assets.g.dart
  echo fixture > packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart
fi
exec fake-gate "$@"
''');
    file('.agent_temp/bin/gh', r'''#!/bin/sh
echo gh >> .agent_temp/gh-calls
if [ "$2" = list ]; then echo '[{"databaseId":42,"conclusion":"success"}]'; exit 0; fi
if [ -f .agent_temp/ci-jobs.json ]; then cat .agent_temp/ci-jobs.json; exit 0; fi
if [ -f .agent_temp/skipped-ci ]; then
  echo '{"url":"https://example.test/run/42","jobs":[{"name":"Check","conclusion":"success"}]}'
else
  echo '{"url":"https://example.test/run/42","jobs":[{"name":"Check","conclusion":"success"},{"name":"Container boundary","conclusion":"success"},{"name":"PowerShell scripts","conclusion":"success"},{"name":"PostgreSQL contract","conclusion":"success"}]}'
fi
''');
    for (final name in ['fake-gate', 'dart', 'gh']) {
      Process.runSync('chmod', ['755', file('.agent_temp/bin/$name').path]);
    }
    environment = {'PATH': '${p.join(fixture.path, '.agent_temp/bin')}:${Platform.environment['PATH']}'};
    git(['init', '--quiet']);
    git(['add', '.']);
    git([
      '-c',
      'user.name=Release test',
      '-c',
      'user.email=release@example.test',
      'commit',
      '--quiet',
      '-m',
      'Fixture',
    ]);
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  test('dirty candidates cannot acquire release evidence', () {
    file('untracked-input', 'pending');
    final result = run(['--local']);
    expect(result.exitCode, 1);
    expect('${result.stdout}${result.stderr}', contains('clean worktree'));
    expect(file('.agent_temp/calls').existsSync(), isFalse);
  });

  test('local run records candidate-bound results without GitHub and resume retains successes', () {
    final first = run(['--local']);
    expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
    expect(file('.agent_temp/gh-calls').existsSync(), isFalse);
    final receipt = jsonDecode(receipts('tests').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'passed');
    expect(receipt['exitCode'], 0);
    expect((receipt['candidate'] as Map)['head'], hasLength(40));
    expect((receipt['candidate'] as Map)['tree'], hasLength(40));
    expect(receipt['startedAt'], isNotEmpty);
    expect(receipt['finishedAt'], isNotEmpty);
    expect(receipt['logHash'], isNotEmpty);
    expect(run(['--local', '--resume']).exitCode, 0);
    expect(receipts('tests'), hasLength(1));
    expect(receipts('dependencies'), hasLength(2), reason: 'ignored dependency state must be rebuilt');
    final calls = file('.agent_temp/calls').readAsStringSync();
    expect(run(['--local', '--status']).exitCode, 0);
    expect(file('.agent_temp/calls').readAsStringSync(), calls, reason: 'status does not execute gates');
    final all = run(['--status']);
    expect(all.exitCode, 3);
    expect(all.stdout, contains('ci: missing'));
  });

  test('quick mode cannot report complete automated coverage', () {
    final result = run(['--local', '--quick']);
    expect(result.exitCode, 3, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('tests: skipped'));
    expect(result.stdout, isNot(contains('All automated gates passed')));
  });

  test('failures retain evidence and a retry cannot reuse an earlier success', () {
    expect(run(['--gate', 'versions']).exitCode, 0);
    file('.agent_temp/fail', 'fail');
    expect(run(['--gate', 'versions']).exitCode, 1);
    expect(receipts('versions'), hasLength(2));
    expect(run(['--gate', 'versions', '--resume']).exitCode, 1);
    expect(receipts('versions'), hasLength(3));
    file('.agent_temp/fail').deleteSync();
    expect(run(['--gate', 'versions', '--resume']).exitCode, 0);
    expect(receipts('versions'), hasLength(4));
  });

  test('new commits, dirty files, environment changes and damaged logs invalidate passes', () {
    expect(run(['--gate', 'versions']).exitCode, 0);
    environment['DARTCLAW_RELEASE_TEST_CONTEXT'] = 'changed';
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: stale'));
    environment.remove('DARTCLAW_RELEASE_TEST_CONTEXT');
    file('pubspec.lock', 'changed\n');
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: stale'));
    git(['add', 'pubspec.lock']);
    git(['-c', 'user.name=Release test', '-c', 'user.email=release@example.test', 'commit', '--quiet', '-m', 'Change']);
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: stale'));
    expect(run(['--gate', 'versions', '--resume']).exitCode, 0);
    final latest = receipts('versions')..sort((a, b) => a.path.compareTo(b.path));
    File(p.join(latest.last.parent.path, 'output.log')).writeAsStringSync('tampered');
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: stale'));
  });

  test('source changes during a successful command invalidate the attempt', () {
    file('.agent_temp/drift', 'drift');
    final result = run(['--gate', 'versions']);
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final receipt = jsonDecode(receipts('versions').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'failed');
    expect(receipt['exitCode'], isNot(0));
  });

  test('CI evidence requires every named job and is refreshed on resume', () {
    expect(run(['--gate', 'ci']).exitCode, 0);
    final receipt = jsonDecode(receipts('ci').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['ciRunUrl'], 'https://example.test/run/42');
    file('.agent_temp/skipped-ci', 'skip');
    expect(run(['--gate', 'ci', '--resume']).exitCode, 1);
    expect(receipts('ci'), hasLength(2));
  });

  test('every job advertised by the CI workflow is required by release qualification', () {
    final workflow = loadYaml(File(p.join(repo, '.github/workflows/ci.yml')).readAsStringSync()) as YamlMap;
    final jobs = (workflow['jobs'] as YamlMap).values.cast<YamlMap>().map((job) => job['name'] as String).toList();
    expect(jobs, isNotEmpty);
    void writeJobs(List<String> names) {
      file(
        '.agent_temp/ci-jobs.json',
        jsonEncode({
          'url': 'https://example.test/run/42',
          'jobs': [
            for (final name in names) {'name': name, 'conclusion': 'success'},
          ],
        }),
      );
    }

    writeJobs(jobs);
    expect(run(['--gate', 'ci']).exitCode, 0, reason: 'The complete current CI workflow must qualify');
    for (final missing in jobs) {
      writeJobs(jobs.where((name) => name != missing).toList());
      expect(run(['--gate', 'ci']).exitCode, 1, reason: 'Missing current CI job $missing must block release');
    }
  });

  test('unknown gate and conflicting scopes fail before execution', () {
    expect(run(['--gate', 'typo']).exitCode, 2);
    expect(run(['--local', '--gate', 'ci']).exitCode, 2);
    expect(file('.agent_temp/calls').existsSync(), isFalse);
  });

  test('interrupted or malformed receipts never count as passes', () {
    expect(run(['--gate', 'versions']).exitCode, 0);
    final receiptFile = receipts('versions').single;
    final receipt = jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    receipt['status'] = 'running';
    receiptFile.writeAsStringSync(jsonEncode(receipt));
    final receiptHash = Process.runSync('git', ['hash-object', receiptFile.path], workingDirectory: fixture.path);
    File(p.join(receiptFile.parent.path, 'receipt.hash')).writeAsStringSync((receiptHash.stdout as String).trim());
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: incomplete'));
    receiptFile.writeAsStringSync('{');
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: stale'));
    expect(run(['--gate', 'versions', '--resume']).exitCode, 0);
    expect(receipts('versions'), hasLength(2));
  });

  test('damaged receipt metadata cannot retain a passed audit result', () {
    expect(run(['--gate', 'ci']).exitCode, 0);
    final receiptFile = receipts('ci').single;
    final original = receiptFile.readAsStringSync();
    for (final field in ['startedAt', 'finishedAt', 'log', 'ciRunId', 'ciRunUrl']) {
      final changed = jsonDecode(original) as Map<String, dynamic>;
      changed.remove(field);
      receiptFile.writeAsStringSync(jsonEncode(changed));
      expect(run(['--gate', 'ci', '--status']).stdout, contains('ci: stale'), reason: 'Missing $field must invalidate');
    }
    final changed = jsonDecode(original) as Map<String, dynamic>;
    changed['startedAt'] = '2000-01-01T00:00:00.000Z';
    receiptFile.writeAsStringSync(jsonEncode(changed));
    expect(
      run(['--gate', 'ci', '--status']).stdout,
      contains('ci: stale'),
      reason: 'Valid metadata edits must invalidate',
    );
  });

  test('missing tracked lockfile fails before dependency installation can mask it', () {
    git(['rm', 'pubspec.lock']);
    git([
      '-c',
      'user.name=Release test',
      '-c',
      'user.email=release@example.test',
      'commit',
      '--quiet',
      '-m',
      'Missing lock',
    ]);
    expect(run(['--gate', 'dependencies']).exitCode, 1);
    expect(file('.agent_temp/calls').existsSync(), isFalse);
  });

  test('exported bundles block qualification before expensive gates', () {
    file('dev/bundle/spec.md', 'transient');
    git(['add', 'dev/bundle/spec.md']);
    git(['-c', 'user.name=Release test', '-c', 'user.email=release@example.test', 'commit', '--quiet', '-m', 'Bundle']);
    final result = run(['--local']);
    expect(result.exitCode, 1);
    expect('${result.stdout}${result.stderr}', contains('Transient release inputs'));
    expect(file('.agent_temp/calls').existsSync(), isFalse);
  });
}

String _findRoot(String start) {
  var current = start;
  while (!File(p.join(current, 'dev/tools/release_check.sh')).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Repository root not found');
    current = parent;
  }
  return current;
}
