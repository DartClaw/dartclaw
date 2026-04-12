import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:test/test.dart';

void main() {
  group('WhatsApp config registration', () {
    test('provider returns disabled defaults when package is imported', () {
      ensureDartclawWhatsappRegistered();

      final config = DartclawConfig.load(fileReader: (_) => null, env: {'HOME': '/home/user'});
      final whatsAppConfig = config.getChannelConfig<WhatsAppConfig>(ChannelType.whatsapp);

      expect(whatsAppConfig.enabled, isFalse);
      expect(whatsAppConfig.gowaExecutable, 'whatsapp');
      expect(whatsAppConfig.groupAccess, GroupAccessMode.disabled);
      expect(whatsAppConfig.requireMention, isTrue);
      expect(whatsAppConfig.taskTrigger.enabled, isFalse);
      expect(whatsAppConfig.taskTrigger.prefix, 'task:');
    });

    test('provider parses whatsapp config when package is imported', () {
      ensureDartclawWhatsappRegistered();

      final config = DartclawConfig.load(
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
    task_trigger:
      enabled: true
      prefix: "do:"
      default_type: coding
      auto_start: false
''';
          }
          return null;
        },
        env: {'HOME': '/home/user'},
      );

      final whatsAppConfig = config.getChannelConfig<WhatsAppConfig>(ChannelType.whatsapp);

      expect(whatsAppConfig.enabled, isTrue);
      expect(whatsAppConfig.gowaExecutable, '/usr/local/bin/gowa');
      expect(whatsAppConfig.gowaHost, 'gowa.internal');
      expect(whatsAppConfig.gowaPort, 4100);
      expect(whatsAppConfig.dmAccess, DmAccessMode.allowlist);
      expect(whatsAppConfig.groupAccess, GroupAccessMode.open);
      expect(whatsAppConfig.requireMention, isFalse);
      expect(whatsAppConfig.mentionPatterns, ['@dartclaw']);
      expect(whatsAppConfig.taskTrigger.enabled, isTrue);
      expect(whatsAppConfig.taskTrigger.prefix, 'do:');
      expect(whatsAppConfig.taskTrigger.defaultType, 'coding');
      expect(whatsAppConfig.taskTrigger.autoStart, isFalse);
    });
  });
}
