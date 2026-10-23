import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final root = Platform.environment['DARTCLAW_REPO_ROOT'] ?? Platform.environment['PWD'] ?? Directory.current.path;
  final repo = _findRoot(root);
  late Directory fixture;

  ProcessResult git(List<String> args) => Process.runSync('git', [
    '-c',
    'user.name=Test',
    '-c',
    'user.email=test@example.test',
    ...args,
  ], workingDirectory: fixture.path);

  ProcessResult script(String name) =>
      Process.runSync('bash', [p.join(repo, 'dev/tools/$name')], workingDirectory: fixture.path);

  void commit(String name, String contents, String message) {
    File(p.join(fixture.path, name))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(contents);
    git(['add', name]);
    expect(git(['commit', '--quiet', '-m', message]).exitCode, 0);
  }

  setUp(() {
    final temp = Directory(p.join(repo, '.agent_temp'))..createSync(recursive: true);
    fixture = temp.createTempSync('release-hygiene-test-');
    expect(git(['init', '--quiet', '-b', 'main']).exitCode, 0);
  });

  tearDown(() => fixture.deleteSync(recursive: true));

  group('secret_scan.sh', () {
    test('flags a provider-shaped token and accepts the same text split at runtime', () {
      // Split so this file itself stays clean under the scan.
      final token =
          'xox'
          'b-1111111111-2222222222-AbCdEfGhIjKlMnOpQrStUvWx';
      commit('fixture.dart', "const t = 'ok';\n", 'clean');
      expect(script('secret_scan.sh').exitCode, 0);

      commit('fixture.dart', "const t = '$token';\n", 'leaky');
      final result = script('secret_scan.sh');
      expect(result.exitCode, 1);
      expect(result.stderr, contains('fixture.dart:1'));

      commit('fixture.dart', "const t = 'xox' 'b-1111111111-2222222222-AbCdEfGhIjKlMnOpQrStUvWx';\n", 'split');
      expect(script('secret_scan.sh').exitCode, 0);
    });
  });

  group('check_doc_cuts.sh', () {
    test('fails on a large net doc cut until a Docs-Cut message acknowledges it', () {
      commit('docs/big.md', List.filled(1500, 'line').join('\n'), 'base');
      git(['checkout', '--quiet', '-b', 'feat']);
      commit('docs/big.md', 'short\n', 'rewrite');

      final failed = script('check_doc_cuts.sh');
      expect(failed.exitCode, 1);
      expect(failed.stderr, contains('docs/big.md'));

      expect(git(['commit', '--quiet', '--allow-empty', '-m', 'Docs-Cut: superseded by the guide']).exitCode, 0);
      expect(script('check_doc_cuts.sh').exitCode, 0);
    });

    test('a cut under the limit passes and dev/bundle is exempt', () {
      commit('docs/small.md', List.filled(200, 'line').join('\n'), 'base');
      commit('dev/bundle/old.md', List.filled(3000, 'line').join('\n'), 'bundle');
      git(['checkout', '--quiet', '-b', 'feat']);
      commit('docs/small.md', 'short\n', 'trim');
      git(['rm', '--quiet', 'dev/bundle/old.md']);
      expect(git(['commit', '--quiet', '-m', 'drop bundle']).exitCode, 0);

      expect(script('check_doc_cuts.sh').exitCode, 0);
    });
  });
}

String _findRoot(String start) {
  var dir = Directory(start).absolute;
  while (!File(p.join(dir.path, 'dev/tools/release_check.dart')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('Repository root not found from $start');
    dir = parent;
  }
  return dir.path;
}
