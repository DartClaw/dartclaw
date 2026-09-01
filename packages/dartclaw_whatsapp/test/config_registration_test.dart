import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:test/test.dart';

WhatsAppConfig _whatsAppConfigOf(DartclawConfig config, List<String> warns) =>
    WhatsAppConfig.fromYaml(config.channels.channelConfigs['whatsapp'] ?? const {}, warns);

void main() {
  group('WhatsApp config resolution', () {
    test('a config file without a channels block yields disabled defaults', () {
      final config = DartclawConfig.load(fileReader: (_) => null, env: {'HOME': '/home/user'});
      final warns = <String>[];
      final whatsAppConfig = _whatsAppConfigOf(config, warns);

      expect(whatsAppConfig.enabled, isFalse);
      expect(whatsAppConfig.gowaExecutable, 'whatsapp');
      expect(whatsAppConfig.groupAccess, GroupAccessMode.disabled);
      expect(whatsAppConfig.requireMention, isTrue);
      expect(warns, isEmpty);
    });

    test('the whatsapp section of a loaded config parses into WhatsAppConfig', () {
      final config = DartclawConfig.load(
        configPath: 'dartclaw.yaml',
        fileReader: (path) {
          if (path == 'dartclaw.yaml') {
            return '''
channels:
  whatsapp:
    enabled: true
    gowa_executable: /usr/local/bin/gowa
    gowa_host: gowa.internal
    gowa_port: 4100
    dm_access: allowlist
    group_access: open
    require_mention: false
    mention_patterns:
      - "@dartclaw"
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      final whatsAppConfig = _whatsAppConfigOf(config, <String>[]);

      expect(whatsAppConfig.enabled, isTrue);
      expect(whatsAppConfig.gowaExecutable, '/usr/local/bin/gowa');
      expect(whatsAppConfig.gowaHost, 'gowa.internal');
      expect(whatsAppConfig.gowaPort, 4100);
      expect(whatsAppConfig.dmAccess, DmAccessMode.allowlist);
      expect(whatsAppConfig.groupAccess, GroupAccessMode.open);
      expect(whatsAppConfig.requireMention, isFalse);
      expect(whatsAppConfig.mentionPatterns, ['@dartclaw']);
    });

    test('registered access vocabularies match the shared mappers', () {
      expect(
        ConfigMeta.fields['channels.whatsapp.dm_access']!.allowedValues!.toSet(),
        DmAccessMode.values.map((value) => value.name).toSet(),
      );
      expect(
        ConfigMeta.fields['channels.whatsapp.group_access']!.allowedValues!.toSet(),
        GroupAccessMode.values.map((value) => value.name).toSet(),
      );
    });

    test('invalid access values keep channel-specific warnings and defaults', () {
      final warns = <String>[];
      final config = WhatsAppConfig.fromYaml({'dm_access': 'bogus', 'group_access': 'pairing'}, warns);

      expect(config.dmAccess, DmAccessMode.pairing);
      expect(config.groupAccess, GroupAccessMode.disabled);
      expect(warns, [
        'Invalid whatsapp.dm_access: "bogus" — using default',
        'Invalid whatsapp.group_access: "pairing" — using default',
      ]);
    });
  });
}
