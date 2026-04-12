import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:test/test.dart';

void main() {
  group('Signal config registration', () {
    test('provider returns disabled defaults when package is imported', () {
      ensureDartclawSignalRegistered();

      final config = DartclawConfig.load(fileReader: (_) => null, env: {'HOME': '/home/user'});
      final signalConfig = config.getChannelConfig<SignalConfig>(ChannelType.signal);

      expect(signalConfig.enabled, isFalse);
      expect(signalConfig.executable, 'signal-cli');
      expect(signalConfig.groupAccess, SignalGroupAccessMode.disabled);
      expect(signalConfig.requireMention, isTrue);
      expect(signalConfig.taskTrigger.enabled, isFalse);
      expect(signalConfig.taskTrigger.prefix, 'task:');
    });

    test('provider parses signal config when package is imported', () {
      ensureDartclawSignalRegistered();

      final config = DartclawConfig.load(
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
    task_trigger:
      enabled: true
      prefix: "do:"
      default_type: analysis
      auto_start: false
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      final signalConfig = config.getChannelConfig<SignalConfig>(ChannelType.signal);

      expect(signalConfig.enabled, isTrue);
      expect(signalConfig.phoneNumber, '+46700000000');
      expect(signalConfig.executable, '/usr/local/bin/signal-cli');
      expect(signalConfig.host, 'signal.internal');
      expect(signalConfig.port, 9000);
      expect(signalConfig.dmAccess, DmAccessMode.pairing);
      expect(signalConfig.groupAccess, SignalGroupAccessMode.open);
      expect(signalConfig.requireMention, isFalse);
      expect(signalConfig.mentionPatterns, ['@signal-bot']);
      expect(signalConfig.taskTrigger.enabled, isTrue);
      expect(signalConfig.taskTrigger.prefix, 'do:');
      expect(signalConfig.taskTrigger.defaultType, 'analysis');
      expect(signalConfig.taskTrigger.autoStart, isFalse);
    });

    test('provider surfaces signal config warnings during load', () {
      ensureDartclawSignalRegistered();

      final config = DartclawConfig.load(
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

      expect(config.warnings, anyElement(contains('Invalid type for signal.port')));
      config.getChannelConfig<SignalConfig>(ChannelType.signal);
      final warningCount = config.warnings.length;
      config.getChannelConfig<SignalConfig>(ChannelType.signal);
      expect(config.warnings, hasLength(warningCount));
    });
  });
}
