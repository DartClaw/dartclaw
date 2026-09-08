@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show PlatformCapabilities;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

void main() {
  for (final dedicated in [false, true]) {
    test('Codex consumes a user-only plugin in ${dedicated ? 'dedicated' : 'system'} home mode', () async {
      expect(await codexAvailable(), isTrue, reason: 'This live canary requires an installed Codex CLI.');
      final sourceHome = Platform.environment['CODEX_HOME'] ?? p.join(Platform.environment['HOME']!, '.codex');
      final sourceAuth = File(p.join(sourceHome, 'auth.json'));
      expect(sourceAuth.existsSync(), isTrue, reason: 'Log in to Codex before running this live canary.');
      final tempRoot = Directory(p.join(workflowRepositoryRoot(), '.agent_temp'))..createSync(recursive: true);
      final fixture = tempRoot.createTempSync('codex-user-plugin-');
      addTearDown(() => fixture.delete(recursive: true));
      final operatorHome = Directory(p.join(fixture.path, 'custom-codex-home'))..createSync();
      final dedicatedHome = Directory(p.join(fixture.path, 'subscription'))..createSync();
      final cwd = Directory(p.join(fixture.path, 'workspace'))..createSync();
      final plugin = Directory(p.join(operatorHome.path, 'plugins', 'cache', 'fixture', 'scope-fixture', '1.0.0'))
        ..createSync(recursive: true);
      final manifest = File(p.join(plugin.path, '.codex-plugin', 'plugin.json'))..parent.createSync();
      manifest.writeAsStringSync(jsonEncode({'name': 'scope-fixture', 'version': '1.0.0', 'skills': './skills/'}));
      final skill = File(p.join(plugin.path, 'skills', 'probe', 'SKILL.md'))..parent.createSync(recursive: true);
      final sentinel = 'plugin-body-${DateTime.now().microsecondsSinceEpoch}';
      skill.writeAsStringSync('''---
name: probe
description: Return the plugin fixture verification token.
---
Return exactly this token and nothing else: $sentinel
''');
      final model = Platform.environment['DARTCLAW_TEST_EXECUTOR_MODEL'] ?? 'gpt-5.6-luna';
      File(p.join(operatorHome.path, 'config.toml')).writeAsStringSync('''model = "$model"

[plugins."scope-fixture@fixture"]
enabled = true
''');
      // Each fixture receives its own login copy; production mirroring must never copy it.
      await secureWriteFile(File(p.join(operatorHome.path, 'auth.json')), sourceAuth.readAsStringSync());
      await secureWriteFile(File(p.join(dedicatedHome.path, 'auth.json')), sourceAuth.readAsStringSync());
      final environment = <String, String>{
        for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
          key: ?Platform.environment[key],
        'CODEX_HOME': operatorHome.path,
      };
      final harness = HarnessFactory().create(
        'codex',
        HarnessFactoryConfig(
          cwd: cwd.path,
          executable: 'codex',
          turnTimeout: const Duration(minutes: 2),
          providerOptions: const {'sandbox': 'read-only', 'approval': 'never'},
          declaredCanonicalTools: const ['file_read'],
          environment: environment,
          platformCapabilities: PlatformCapabilities(environment: environment),
          prepareSubscriptionHome: dedicated ? () async => dedicatedHome.path : null,
        ),
      );
      final expectedSkill = File(
        p.join(
          dedicated ? dedicatedHome.path : operatorHome.path,
          'plugins',
          'cache',
          'fixture',
          'scope-fixture',
          '1.0.0',
          'skills',
          'probe',
          'SKILL.md',
        ),
      );
      final response = StringBuffer();
      final subscription = harness.events.listen((event) {
        if (event is DeltaEvent) response.write(event.text);
      });
      try {
        await harness.start();
        expect(expectedSkill.readAsStringSync(), contains(sentinel));
        await harness.turn(
          sessionId: 'user-plugin-${dedicated ? 'dedicated' : 'system'}',
          model: model,
          messages: const [
            {
              'role': 'user',
              'content': '\$scope-fixture:probe\nUse this enabled plugin skill and return its verification token.',
            },
          ],
          systemPrompt: '',
          directory: cwd.path,
        );
      } finally {
        await subscription.cancel();
        await harness.stop();
        await harness.dispose();
      }
      expect(response.toString(), contains(sentinel), reason: 'Only the user plugin body contains the token.');
      expect(Directory(p.join(cwd.path, '.agents')).existsSync(), isFalse);
      expect(Directory(p.join(cwd.path, '.codex')).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
