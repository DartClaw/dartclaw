import 'package:dartclaw/dartclaw.dart';
import 'package:test/test.dart';

void main() {
  group('dartclaw umbrella exports', () {
    test('re-exports core, models, security, storage, and channel types', () async {
      final session = Session(
        id: 'session-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final guardConfig = const GuardConfig.defaults();
      final eventBus = EventBus();
      final googleChatAudience = const GoogleChatAudienceConfig(
        mode: GoogleChatAudienceMode.appUrl,
        value: 'https://chat.google.com',
      );
      final googleChatConfig = GoogleChatConfig(audience: googleChatAudience);
      final signalConfig = const SignalConfig();
      final whatsappConfig = const WhatsAppConfig();

      expect(session.type, SessionType.user);
      expect(guardConfig.enabled, isTrue);
      expect(eventBus.isDisposed, isFalse);
      expect(googleChatConfig.audience, same(googleChatAudience));
      expect(signalConfig.port, 8080);
      expect(whatsappConfig.gowaPort, 3000);

      expect(AgentHarness, isNotNull);
      expect(Channel, isNotNull);
      expect(Guard, isNotNull);
      expect(MemoryService, isNotNull);
      expect(GoogleChatChannel, isNotNull);
      expect(SignalChannel, isNotNull);
      expect(WhatsAppChannel, isNotNull);

      await eventBus.dispose();
      expect(eventBus.isDisposed, isTrue);
    });

    test('channel registration helpers are available from the umbrella import', () {
      ensureDartclawGoogleChatRegistered();
      ensureDartclawSignalRegistered();
      ensureDartclawWhatsappRegistered();

      final config = DartclawConfig.load(
        fileReader: (_) => null,
        env: const {'HOME': '/home/testuser'},
      );

      expect(
        config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat),
        isA<GoogleChatConfig>(),
      );
      expect(
        config.getChannelConfig<SignalConfig>(ChannelType.signal),
        isA<SignalConfig>(),
      );
      expect(
        config.getChannelConfig<WhatsAppConfig>(ChannelType.whatsapp),
        isA<WhatsAppConfig>(),
      );
    });
  });
}
