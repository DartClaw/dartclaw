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

      final secretPath = p.join(dataDir.path, 'projects', '.git-askpass-deploy.$secretSuffix');
      expect(plan.environment['GIT_ASKPASS'], p.join(dataDir.path, 'projects', '.git-askpass-deploy'));
      expect(tempFiles, contains(secretPath));
      expect(modeOf(secretPath), 0x180);
      expect(modeOf(plan.environment['GIT_ASKPASS']!) & 0x3f, 0, reason: 'the script is owner-only too');
    });
  }
}
