import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:test/test.dart';

String? Function(String) _yaml(String contents) =>
    (path) => path == 'dartclaw.yaml' ? contents : null;

void main() {
  group('resolveChannelConfig', () {
    test('resolves every channel off a config that was never loaded from disk', () {
      const config = DartclawConfig.defaults();

      expect(resolveChannelConfig<GoogleChatConfig>(config, ChannelType.googlechat).enabled, isFalse);
      expect(resolveChannelConfig<SignalConfig>(config, ChannelType.signal).executable, 'signal-cli');
      expect(resolveChannelConfig<WhatsAppConfig>(config, ChannelType.whatsapp).gowaExecutable, 'whatsapp');
    });

    test('rejects ChannelType.web, which has no config section', () {
      const config = DartclawConfig.defaults();

      expect(() => resolveChannelConfig<Object>(config, ChannelType.web), throwsArgumentError);
    });

    test('rejects a requested type the channel config is not assignable to', () {
      const config = DartclawConfig.defaults();

      expect(() => resolveChannelConfig<SignalConfig>(config, ChannelType.googlechat), throwsArgumentError);
    });

    test('parses a channel section once per config, so its warning is not duplicated', () {
      final config = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: _yaml('channels:\n  signal:\n    port: nope\n'),
        env: const {'HOME': '/home/user'},
      );

      final warningCount = config.warnings.length;
      final first = resolveChannelConfig<SignalConfig>(config, ChannelType.signal);
      final second = resolveChannelConfig<SignalConfig>(config, ChannelType.signal);

      expect(second, same(first));
      expect(config.warnings, hasLength(warningCount));
      expect(config.warnings.where((w) => w.contains('Invalid type for signal.port')), hasLength(1));
    });
  });

  group('loadDartclawConfig', () {
    test('surfaces every channel section warning before any channel config is read', () {
      final config = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: _yaml('''
channels:
  google_chat:
    typing_indicator: invalid
  signal:
    port: nope
  whatsapp:
    gowa_port: invalid
'''),
        env: const {'HOME': '/home/user'},
      );

      expect(config.warnings, contains('Invalid google_chat.typing_indicator: "invalid" — using default'));
      expect(config.warnings, contains('Invalid type for signal.port: "String" — using default'));
      expect(config.warnings, contains('Invalid type for whatsapp.gowa_port: "String" — using default'));
    });

    test('a config with no channels block loads without channel warnings', () {
      final config = loadDartclawConfig(fileReader: (_) => null, env: const {'HOME': '/home/user'});

      expect(config.warnings, isEmpty);
    });

    test('a hot reload is refused on a channel parse warning and leaves the config in force', () {
      final running = loadDartclawConfig(fileReader: (_) => null, env: const {'HOME': '/home/user'});
      final notifier = ConfigNotifier(running);

      final edited = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: _yaml('channels:\n  signal:\n    port: nope\n'),
        env: const {'HOME': '/home/user'},
      );

      expect(() => notifier.reload(edited), throwsFormatException);
      expect(notifier.current, same(running));
    });
  });

  group('unknown bound agent', () {
    const boundRow = '''
channels:
  whatsapp:
    dm_allowlist:
      - id: 46700000001@s.whatsapp.net
        agent: nope
''';

    test('a row binding an undeclared agent refuses the load, naming channel, row and agent', () {
      expect(
        () => loadDartclawConfig(configPath: 'dartclaw.yaml', fileReader: _yaml(boundRow), env: const {'HOME': '/h'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('channels.whatsapp.dm_allowlist'),
              contains('46700000001@s.whatsapp.net'),
              contains('"nope"'),
              contains('Declared agents: none'),
            ),
          ),
        ),
      );
    });

    test('a group row binding an undeclared agent is refused too, naming the declared set', () {
      const config = '''
agent:
  agents:
    ana:
      prompt: You are Ana.
channels:
  google_chat:
    group_allowlist:
      - id: spaces/AAA
        agent: bob
''';
      expect(
        () => loadDartclawConfig(configPath: 'dartclaw.yaml', fileReader: _yaml(config), env: const {'HOME': '/h'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('channels.google_chat.group_allowlist'),
              contains('"bob"'),
              contains('Declared agents: ana'),
            ),
          ),
        ),
      );
    });

    test('the same row loads once the agent is declared', () {
      const config = '''
agent:
  agents:
    nope:
      prompt: Actually declared.
$boundRow''';
      final loaded = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: _yaml(config),
        env: const {'HOME': '/h'},
      );

      expect(resolveChannelConfig<WhatsAppConfig>(loaded, ChannelType.whatsapp).dmAllowlist.single.agent, 'nope');
    });

    test('a present agent must be a non-blank string', () {
      const invalidValues = ['7', 'true', '[ana]', '{name: ana}', '""', '"   "'];
      for (final field in ['dm_allowlist', 'group_allowlist']) {
        for (final value in invalidValues) {
          final yaml =
              '''
channels:
  signal:
    $field:
      - id: "+46700000001"
        agent: $value
''';
          expect(
            () => loadDartclawConfig(configPath: 'dartclaw.yaml', fileReader: _yaml(yaml), env: const {'HOME': '/h'}),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                allOf(startsWith('channels.signal.$field'), contains('+46700000001'), contains('agent')),
              ),
            ),
            reason: '$field agent: $value',
          );
        }
      }
    });

    test('plain-string DM rows load with no warning, and a malformed DM map now warns by field', () {
      final plain = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: _yaml('channels:\n  signal:\n    dm_allowlist:\n      - "+46700000002"\n'),
        env: const {'HOME': '/h'},
      );
      expect(plain.warnings, isEmpty);

      final malformed = loadDartclawConfig(
        configPath: 'dartclaw.yaml',
        fileReader: _yaml('channels:\n  signal:\n    dm_allowlist:\n      - agent: ana\n'),
        env: const {'HOME': '/h'},
      );
      expect(malformed.warnings.single, startsWith('signal.dm_allowlist: map missing or invalid "id"'));
    });
  });
}
