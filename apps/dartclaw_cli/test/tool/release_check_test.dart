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

  String git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: fixture.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return (result.stdout as String).trim();
  }

  void commit(String message) => git([
    '-c',
    'user.name=Release test',
    '-c',
    'user.email=release@example.test',
    'commit',
    '--quiet',
    '-m',
    message,
  ]);

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
    file('dev/tools/check_doc_cuts.sh')
        .writeAsStringSync(File(p.join(repo, 'dev/tools/check_doc_cuts.sh')).readAsStringSync());
    file('.gitignore', '.agent_temp/\n**/generated/\n');
    file('pubspec.lock', 'fixture\n');
    file('dev/tools/mascot_favicon/pubspec.lock', 'fixture\n');
    for (final script in ['check_versions', 'secret_scan', 'test_workspace', 'postgres_contract', 'build']) {
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
  echo '{"url":"https://example.test/run/42","jobs":[{"name":"Check","conclusion":"success"},{"name":"PowerShell scripts","conclusion":"success"}]}'
fi
''');
    file('dev/tools/lima/linux.yaml', 'mounts: []\n');
    file('.agent_temp/bin/limactl', r'''#!/bin/sh
printf '%s\n' "$*" >> .agent_temp/lima-calls
guest="$PWD/.agent_temp/guest"
case "$1" in
  list) if [ -f .agent_temp/vm-present ]; then echo dartclaw-release-linux; fi ;;
  create) touch .agent_temp/vm-present ;;
  copy)
    if [ -f .agent_temp/fail-copy ]; then exit 6; fi
    git bundle verify "$2" >/dev/null 2>&1 &&
      git bundle list-heads "$2" > .agent_temp/bundle-heads &&
      cp "$2" "${3#*:}" ;;
  start) if [ -f .agent_temp/fail-vm ]; then echo 'VM unreachable' >&2; exit 8; fi ;;
  shell)
    shift 2
    case "$*" in
      *mktemp*) mkdir "$guest" && printf '%s\n' "$guest" ;;
      *release_check.sh*)
        if [ -f .agent_temp/fail-linux-gate ]; then echo 'tests: failed (exit 7)' >&2; exit 7; fi
        (cd "$guest/repo" && bash dev/tools/check_doc_cuts.sh) || exit $?
        main=$(git -C "$guest/repo" rev-parse --verify refs/heads/main) || exit $?
        echo "Guest main: $main"
        echo 'Local automated gates passed.' ;;
      *profiles/container/run.sh*)
        if [ -f .agent_temp/fail-posture ]; then echo 'Container posture failed' >&2; exit 9; fi
        echo 'Container posture passed' ;;
      'sudo rm -rf -- '*) [ "$5" = "$guest" ] && rm -rf -- "$guest" ;;
      *) "$@" ;;
    esac ;;
esac
''');
    for (final name in ['fake-gate', 'dart', 'gh', 'limactl']) {
      Process.runSync('chmod', ['755', file('.agent_temp/bin/$name').path]);
    }
    environment = {
      'PATH': '${p.join(fixture.path, '.agent_temp/bin')}:${Platform.environment['PATH']}',
      'DOC_CUT_LIMIT': '1000',
    };
    git(['init', '--quiet', '--initial-branch', 'main']);
    file('README.md', 'Fixture\nOne line to cut\n');
    git(['add', '.']);
    commit('Fixture');
    git(['branch', 'candidate']);
    file('main-only', 'main\n');
    git(['add', 'main-only']);
    commit('Main advances');
    git(['switch', '--quiet', 'candidate']);
    file('README.md', 'Fixture\n');
    git(['add', 'README.md']);
    commit('Candidate cuts one doc line');
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

  test('linux gate fails naming brew install lima without limactl', () {
    file('.agent_temp/bin/limactl').deleteSync();
    environment['PATH'] = '${p.join(fixture.path, '.agent_temp/bin')}:/usr/bin:/bin';
    final result = run(['--gate', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('brew install lima'));
    final receipt = jsonDecode(receipts('linux').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'failed');
    expect(file('.agent_temp/lima-calls').existsSync(), isFalse);
  });

  test('local run includes the linux gate and the omission option skips it', () {
    final result = run(['--local']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final output = result.stdout as String;
    expect(output.indexOf('linux: running'), greaterThan(output.indexOf('whitespace: passed')));
    expect(receipts('linux'), hasLength(1));
    expect(file('.agent_temp/gh-calls').existsSync(), isFalse);
    final calls = file('.agent_temp/lima-calls').readAsStringSync();
    expect(calls, contains('--local --omit linux,ci'));
    expect(calls, isNot(contains(' gh ')));
    final omitted = run(['--local', '--omit', 'linux,ci']);
    expect(omitted.exitCode, 0, reason: '${omitted.stdout}\n${omitted.stderr}');
    expect(omitted.stdout, isNot(contains('linux:')));
    expect(omitted.stdout, isNot(contains('ci:')));
    expect(file('.agent_temp/lima-calls').readAsStringSync(), calls);
    expect(file('.agent_temp/gh-calls').existsSync(), isFalse);
    expect(run(['--local', '--omit', 'typo']).exitCode, 2);
    expect(run(['--gate', 'linux', '--omit', 'linux']).exitCode, 2);
  });

  test('linux gate runs the candidate in the VM', () {
    final main = git(['rev-parse', 'refs/heads/main']);
    final base = git(['merge-base', 'HEAD', 'refs/heads/main']);
    expect(main, isNot(base));
    final result = run(['--gate', 'linux']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final receiptFile = receipts('linux').single;
    final receipt = jsonDecode(receiptFile.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'passed');
    final candidate = receipt['candidate'] as Map<String, dynamic>;
    expect(candidate['head'], isNot(main));
    expect(
      file('.agent_temp/bundle-heads').readAsLinesSync(),
      unorderedEquals(['${candidate['head']} HEAD', '$main refs/heads/main']),
    );
    final calls = file('.agent_temp/lima-calls').readAsLinesSync();
    expect(calls.take(4), [
      'list --format {{.Name}}',
      'create --tty=false --name=dartclaw-release-linux dev/tools/lima/linux.yaml',
      'start --tty=false dartclaw-release-linux',
      'shell dartclaw-release-linux true',
    ]);
    final text = calls.join('\n');
    expect(text.indexOf('git clone --quiet'), greaterThan(text.indexOf('copy ')));
    expect(text, contains('git checkout --quiet --detach ${candidate['head']}'));
    expect(text, contains('test "\$(git rev-parse HEAD^{tree})" = ${candidate['tree']}'));
    expect(text, contains('DARTCLAW_NATIVE_ALLOW_DOWNLOAD=1 bash dev/tools/release_check.sh'));
    expect(text, contains('--local --omit linux,ci'));
    expect(
      text.indexOf('sudo -E env "PATH=\$PATH" bash dev/testing/profiles/container/run.sh --ci'),
      greaterThan(text.indexOf('release_check.sh')),
    );
    expect(file('.agent_temp/gh-calls').existsSync(), isFalse);
    final log = File(p.join(receiptFile.parent.path, 'output.log')).readAsStringSync();
    expect(log, contains('Linux candidate: ${candidate['head']} tree ${candidate['tree']}'));
    expect(log, contains('Guest main: $main'));
    expect(log, contains('Doc cuts: 1 net lines in $base..HEAD (limit 1000)'));
    expect(log, contains('Local automated gates passed.'));
    expect(log, contains('Container posture passed'));
  });

  test('linux gate names the failing in-VM gate', () {
    file('.agent_temp/fail-linux-gate', 'fail');
    final result = run(['--gate', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('tests: failed (exit 7)'));
    expect(file('.agent_temp/lima-calls').readAsStringSync(), isNot(contains('profiles/container/run.sh')));
    final receipt = jsonDecode(receipts('linux').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'failed');
  });

  test('linux gate names a failing container posture profile', () {
    file('.agent_temp/fail-posture', 'fail');
    final result = run(['--gate', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('Container posture failed'));
    final receipt = jsonDecode(receipts('linux').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'failed');
  });

  test('linux gate creates the VM once and reuses it', () {
    expect(run(['--gate', 'linux']).exitCode, 0);
    expect(run(['--gate', 'linux']).exitCode, 0);
    final calls = file('.agent_temp/lima-calls').readAsLinesSync();
    expect(calls.where((call) => call.startsWith('create ')), hasLength(1));
    expect(calls.where((call) => call.startsWith('start ')), hasLength(2));
    expect(receipts('linux'), hasLength(2));
  });

  test('linux gate uses disk-backed staging and cleans successful and failed attempts', () {
    final guest = p.join(fixture.path, '.agent_temp/guest');
    for (final failure in [null, 'fail-copy', 'fail-linux-gate', 'fail-posture']) {
      if (failure != null) file('.agent_temp/$failure', 'fail');
      final result = run(['--gate', 'linux']);
      expect(result.exitCode, failure == null ? 0 : 1);
      final latest = receipts('linux')..sort((a, b) => a.path.compareTo(b.path));
      expect(File(p.join(latest.last.parent.path, 'candidate.bundle')).existsSync(), isFalse);
      final calls = file('.agent_temp/lima-calls').readAsStringSync();
      expect(calls, contains(r'mktemp -d "$HOME/.agent_temp/dartclaw-release.XXXXXXXX"'));
      expect(calls.trimRight(), endsWith('shell dartclaw-release-linux sudo rm -rf -- $guest'));
      expect(Directory(guest).existsSync(), isFalse);
      if (failure != 'fail-copy') {
        expect(calls, contains("export TMPDIR='$guest/tmp'"));
        expect(calls, contains(r'mkdir -p "$TMPDIR"'));
      }
      if (failure != null) file('.agent_temp/$failure').deleteSync();
      file('.agent_temp/lima-calls').deleteSync();
    }
  });

  test('linux gate names the unreachable VM and its recreation command', () {
    file('.agent_temp/vm-present', 'present');
    file('.agent_temp/fail-vm', 'fail');
    final result = run(['--gate', 'linux']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('VM dartclaw-release-linux could not be started or reached'));
    expect(result.stderr, contains('limactl create --name=dartclaw-release-linux dev/tools/lima/linux.yaml'));
    expect(file('.agent_temp/lima-calls').readAsStringSync(), isNot(contains('copy ')));
  });

  test('quick mode cannot report complete automated coverage', () {
    final result = run(['--local', '--quick']);
    expect(file('.agent_temp/calls').readAsLinesSync(), isNot(contains('test_workspace')));
    expect(file('.agent_temp/lima-calls').existsSync(), isFalse, reason: 'quick mode must make no Lima calls');
    expect(result.exitCode, 3, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('tests: skipped (--quick)'));
    expect(result.stdout, isNot(contains('All automated gates passed')));
    expect(result.stdout, contains('linux: skipped (--quick)'));
    expect(result.stdout, contains('Selected coverage is incomplete.'));
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
    commit('Change');
    expect(run(['--gate', 'versions', '--status']).stdout, contains('versions: stale'));
    expect(run(['--gate', 'versions', '--resume']).exitCode, 0);
    final latest = receipts('versions')..sort((a, b) => a.path.compareTo(b.path));
    File(p.join(latest.last.parent.path, 'output.log')).writeAsStringSync('tampered');
    final status = run(['--gate', 'versions', '--status']);
    expect(status.stdout, contains('versions: stale'), reason: 'exit=${status.exitCode} stderr=${status.stderr}');
  });

  test('source changes during a successful command invalidate the attempt', () {
    file('.agent_temp/drift', 'drift');
    final result = run(['--gate', 'versions']);
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    final receipt = jsonDecode(receipts('versions').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['status'], 'failed');
    expect(receipt['exitCode'], isNot(0));
  });

  test('CI gate requires exactly the two remaining jobs', () {
    const names = ['Check', 'PowerShell scripts'];
    void writeJobs({String? missing, String? failing}) {
      file(
        '.agent_temp/ci-jobs.json',
        jsonEncode({
          'url': 'https://example.test/run/42',
          'jobs': [
            for (final name in names)
              if (name != missing) {'name': name, 'conclusion': name == failing ? 'failure' : 'success'},
          ],
        }),
      );
    }

    writeJobs();
    final result = run(['--gate', 'ci']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final receipt = jsonDecode(receipts('ci').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['ciRunUrl'], 'https://example.test/run/42');
    for (final name in names) {
      for (final missing in [true, false]) {
        writeJobs(missing: missing ? name : null, failing: missing ? null : name);
        final failure = run(['--gate', 'ci']);
        expect(failure.exitCode, 1);
        expect(failure.stderr, contains(name));
      }
    }
  });

  test('CI evidence requires every named job and is refreshed on resume', () {
    expect(run(['--gate', 'ci']).exitCode, 0);
    final receipt = jsonDecode(receipts('ci').single.readAsStringSync()) as Map<String, dynamic>;
    expect(receipt['ciRunUrl'], 'https://example.test/run/42');
    file('.agent_temp/skipped-ci', 'skip');
    expect(run(['--gate', 'ci', '--resume']).exitCode, 1);
    expect(receipts('ci'), hasLength(2));
  });

  test('CI workflow runs only the fast jobs', () {
    final workflow = loadYaml(File(p.join(repo, '.github/workflows/ci.yml')).readAsStringSync()) as YamlMap;
    final jobs = (workflow['jobs'] as YamlMap).values.cast<YamlMap>().toList();
    expect(jobs.map((job) => job['name']), unorderedEquals(['Check', 'PowerShell scripts']));
    for (final job in jobs) {
      for (final step in (job['steps'] as YamlList).cast<YamlMap>()) {
        final command = step['run'] as String? ?? '';
        for (final heavy in ['test_workspace.sh', 'fitness/run_all.sh', 'postgres_contract.sh', 'container/run.sh']) {
          expect(command, isNot(contains(heavy)), reason: '${job['name']} must leave $heavy to local gates');
        }
      }
    }
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
    commit('Missing lock');
    expect(run(['--gate', 'dependencies']).exitCode, 1);
    expect(file('.agent_temp/calls').existsSync(), isFalse);
  });

  test('exported bundles block qualification before expensive gates', () {
    file('dev/bundle/spec.md', 'transient');
    git(['add', 'dev/bundle/spec.md']);
    commit('Bundle');
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
