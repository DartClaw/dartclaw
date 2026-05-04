import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

void main() {
  group('GitHubWebhookConfig', () {
    setUp(DartclawConfig.clearExtensionParsers);
    tearDown(DartclawConfig.clearExtensionParsers);

    test('ensureGitHubWebhookConfigRegistered parses typed github config', () {
      ensureGitHubWebhookConfigRegistered();
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == '/home/user/.dartclaw/dartclaw.yaml') {
            return '''
github:
  enabled: true
  webhook_secret: secret
  webhook_path: /hooks/github
  triggers:
    - event: pull_request
      actions: [opened]
      labels: [needs-review]
      workflow: code-review
''';
          }
          return null;
        },
        env: const {'HOME': '/home/user'},
      );

      final github = config.extension<GitHubWebhookConfig>('github');
      expect(github.enabled, isTrue);
      expect(github.webhookSecret, 'secret');
      expect(github.webhookPath, '/hooks/github');
      expect(github.triggers.single.actions, ['opened']);
      expect(github.triggers.single.labels, ['needs-review']);
    });

    test('enabled github config warns when webhook_secret is missing', () {
      ensureGitHubWebhookConfigRegistered();
      final config = DartclawConfig.load(
        fileReader: (path) {
          if (path == '/home/user/.dartclaw/dartclaw.yaml') {
            return '''
github:
  enabled: true
''';
          }
          return null;
        },
        env: const {'HOME': '/home/user'},
      );

      expect(config.warnings, contains('github.webhook_secret is missing while github.enabled=true'));
    });
  });
}
