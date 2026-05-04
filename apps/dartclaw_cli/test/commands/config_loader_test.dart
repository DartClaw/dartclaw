import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:test/test.dart';

void main() {
  test('loadCliConfig makes bundled channel parsers available before config load', () {
    final config = loadCliConfig(
      configPath: '/tmp/dartclaw.yaml',
      env: const {'HOME': '/home/testuser'},
      fileReader: (path) => path == '/tmp/dartclaw.yaml'
          ? '''
channels:
  google_chat:
    typing_indicator: invalid
  signal:
    port: invalid
  whatsapp:
    enabled: true
    gowa_port: invalid
'''
          : null,
    );

    expect(() => config.getChannelConfig<Object>(ChannelType.googlechat), returnsNormally);
    expect(() => config.getChannelConfig<Object>(ChannelType.signal), returnsNormally);
    expect(() => config.getChannelConfig<Object>(ChannelType.whatsapp), returnsNormally);
    expect(config.warnings, contains('Invalid google_chat.typing_indicator: "invalid" — using default'));
    expect(config.warnings, contains('Invalid type for signal.port: "String" — using default'));
    expect(config.warnings, contains('Invalid type for whatsapp.gowa_port: "String" — using default'));
  });

  test('loadCliConfig registers the github extension parser', () {
    final config = loadCliConfig(
      configPath: '/tmp/dartclaw.yaml',
      env: const {'HOME': '/home/testuser'},
      fileReader: (path) => path == '/tmp/dartclaw.yaml'
          ? '''
github:
  enabled: true
  webhook_secret: secret
'''
          : null,
    );

    expect(config.extension<GitHubWebhookConfig>('github').enabled, isTrue);
  });
}
