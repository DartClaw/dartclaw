import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:test/test.dart';

SignalConfig _signalConfigOf(DartclawConfig config, List<String> warns) =>
    SignalConfig.fromYaml(config.channels.channelConfigs['signal'] ?? const {}, warns);

void main() {
  group('Signal config resolution', () {
    test('a config file without a channels block yields disabled defaults', () {
      final config = DartclawConfig.load(fileReader: (_) => null, env: {'HOME': '/home/user'});
      final warns = <String>[];
      final signalConfig = _signalConfigOf(config, warns);

      expect(signalConfig.enabled, isFalse);
      expect(signalConfig.executable, 'signal-cli');
      expect(signalConfig.groupAccess, GroupAccessMode.disabled);
      expect(signalConfig.requireMention, isTrue);
      expect(warns, isEmpty);
    });

    test('the signal section of a loaded config parses into SignalConfig', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
channels:
  signal:
    enabled: true
    phone_number: "+46700000000"
    executable: /usr/local/bin/signal-cli
    host: signal.internal
    port: 9000
    dm_access: pairing
    group_access: open
    require_mention: false
    mention_patterns:
      - "@signal-bot"
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      final signalConfig = _signalConfigOf(config, <String>[]);

      expect(signalConfig.enabled, isTrue);
      expect(signalConfig.phoneNumber, '+46700000000');
      expect(signalConfig.executable, '/usr/local/bin/signal-cli');
      expect(signalConfig.host, 'signal.internal');
      expect(signalConfig.port, 9000);
      expect(signalConfig.dmAccess, DmAccessMode.pairing);
      expect(signalConfig.groupAccess, GroupAccessMode.open);
      expect(signalConfig.requireMention, isFalse);
      expect(signalConfig.mentionPatterns, ['@signal-bot']);
    });

    test('an unparseable signal field warns and falls back to the default', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
channels:
  signal:
    port: nope
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      final warns = <String>[];
      final signalConfig = _signalConfigOf(config, warns);

      expect(warns, anyElement(contains('Invalid type for signal.port')));
      expect(signalConfig.port, 8080);
    });
  });
}
