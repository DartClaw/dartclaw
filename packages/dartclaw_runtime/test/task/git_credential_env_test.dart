@TestOn('posix')
library;

import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/task/git_credential_env.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dataDir;

  setUp(() => dataDir = Directory.systemTemp.createTempSync('git_credential_env_test_'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  int modeOf(String path) => File(path).statSync().mode & 0x1ff;

  for (final (label, entry, remote, secretSuffix) in [
    (
      'GitHub token',
      const CredentialEntry.githubToken(token: 'ghp-secret'),
      'https://github.com/acme/app.git',
      'token',
    ),
    ('HTTPS API key', const CredentialEntry(apiKey: 'api-secret'), 'https://git.example.com/acme/app.git', 'key'),
  ]) {
    test('the $label askpass secret file is readable by the owner only', () {
      final tempFiles = <String>[];
      final plan = resolveGitCredentialPlan(
        remote,
        'deploy',
        CredentialsConfig(entries: {'deploy': entry}),
        dataDir: dataDir.path,
        tempFiles: tempFiles,
      );

      final secretPath = p.join(dataDir.path, 'git-askpass', '.git-askpass-deploy.$secretSuffix');
      expect(plan.environment['GIT_ASKPASS'], p.join(dataDir.path, 'git-askpass', '.git-askpass-deploy'));
      expect(tempFiles, contains(secretPath));
      expect(modeOf(secretPath), 0x180);
      expect(modeOf(plan.environment['GIT_ASKPASS']!) & 0x3f, 0, reason: 'the script is owner-only too');
    });
  }

  test('askpass files are written to the owner-only git-askpass directory and never under projects', () {
    final askpassDir = p.join(dataDir.path, 'git-askpass');
    for (final (entry, remote, secretSuffix) in [
      (const CredentialEntry.githubToken(token: 'ghp-secret'), 'https://github.com/acme/app.git', 'token'),
      (const CredentialEntry(apiKey: 'api-secret'), 'https://git.example.com/acme/app.git', 'key'),
    ]) {
      final plan = resolveGitCredentialPlan(
        remote,
        'deploy',
        CredentialsConfig(entries: {'deploy': entry}),
        dataDir: dataDir.path,
        tempFiles: <String>[],
      );

      final askpass = plan.environment['GIT_ASKPASS']!;
      expect(p.dirname(askpass), askpassDir);
      expect(File('$askpass.$secretSuffix').existsSync(), isTrue);
      expect(modeOf(askpassDir), 0x1c0);
      final projectsDir = Directory(p.join(dataDir.path, 'projects'));
      expect(!projectsDir.existsSync() || projectsDir.listSync().isEmpty, isTrue);
    }
  });

  group('the GitHub token askpass', () {
    late String askpass;

    setUp(() {
      askpass = resolveGitCredentialPlan(
        'git@github.com:acme/app.git',
        'deploy',
        const CredentialsConfig(entries: {'deploy': CredentialEntry.githubToken(token: 'ghp-secret')}),
        dataDir: dataDir.path,
        tempFiles: <String>[],
      ).environment['GIT_ASKPASS']!;
    });

    test('answers the prompts real git issues for github.com', () async {
      final plan = resolveGitCredentialPlan(
        'git@github.com:acme/app.git',
        'deploy',
        const CredentialsConfig(entries: {'deploy': CredentialEntry.githubToken(token: 'ghp-secret')}),
        dataDir: dataDir.path,
        tempFiles: <String>[],
      );
      final git = await Process.start(
        'git',
        ['credential', 'fill'],
        environment: {...plan.environment, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'},
      );
      git.stdin.write('protocol=https\nhost=github.com\n\n');
      await git.stdin.close();
      final output = await git.stdout.transform(systemEncoding.decoder).join();
      final errors = await git.stderr.transform(systemEncoding.decoder).join();

      expect(await git.exitCode, 0, reason: errors);
      expect(output, allOf(contains('username=x-access-token\n'), contains('password=ghp-secret\n')));
    });

    for (final (prompt, answer) in [
      ("Username for 'https://github.com': ", 'x-access-token'),
      ("Username for 'https://github.com/acme/app.git': ", 'x-access-token'),
      ("Password for 'https://x-access-token@github.com': ", 'ghp-secret'),
      ("Password for 'https://x-access-token@github.com/acme/app.git': ", 'ghp-secret'),
    ]) {
      test('answers the github.com prompt "$prompt"', () {
        final result = Process.runSync(askpass, [prompt]);
        expect(result.exitCode, 0, reason: result.stderr as String);
        expect((result.stdout as String).trim(), answer);
      });
    }

    for (final prompt in [
      "Username for 'https://github.com.evil.example': ",
      "Password for 'https://x-access-token@github.com.evil.example': ",
      "Username for 'https://github.com@evil.example': ",
      "Password for 'https://x-access-token@github.com@evil.example': ",
      "Username for 'https://evil.example': ",
      "Password for 'https://x-access-token@evil.example': ",
      "Password for 'http://x-access-token@github.com': ",
      "Username for 'https://evil.example/'https://github.com/acme/app.git': ",
      "Password for 'https://x-access-token@evil.example/'https://x-access-token@github.com/acme/app.git': ",
    ]) {
      test('refuses the foreign-host prompt "$prompt"', () {
        final result = Process.runSync(askpass, [prompt]);
        expect(result.exitCode, isNot(0));
        expect(result.stdout, isEmpty);
      });
    }
  });
}
