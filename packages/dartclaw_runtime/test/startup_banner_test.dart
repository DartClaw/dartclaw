import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('startupBannerChannels names every enabled channel, Slack included', () {
    final config = loadDartclawConfig(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? '''
credentials:
  slack_bot:
    api_key: xoxb-1-2-bot
  slack_app:
    api_key: xapp-1-2-app
channels:
  signal:
    enabled: true
  slack:
    enabled: true
    bot_token_credential: slack_bot
    app_token_credential: slack_app
'''
          : null,
      env: const {'HOME': '/home/user'},
    );

    expect(startupBannerChannels(config), ['Signal', 'Slack']);
    expect(
      startupBanner(host: 'localhost', port: 3000, channels: startupBannerChannels(config)),
      contains('Signal, Slack'),
    );
  });
}
