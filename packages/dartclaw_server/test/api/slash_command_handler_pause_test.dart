import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('SlashCommandHandler — pause/resume', () {
    const adminJid = 'users/admin@example.com';
    const userJid = 'users/user@example.com';
    const spaceName = 'spaces/AAAA';

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    final drainedSessions = <Map<String, String>>[];

    SlashCommandHandler buildHandler({
      PauseController? pauseController,
      bool Function(String)? isAdmin,
    }) {
      drainedSessions.clear();
      return SlashCommandHandler(
        pauseController: pauseController,
        isAdmin: isAdmin ?? (jid) => jid == adminJid,
        onDrain: (collapsed) async {
          drainedSessions.add(collapsed);
        },
      );
    }

    Future<Map<String, dynamic>> invoke(SlashCommandHandler handler, String command, {String senderJid = adminJid}) {
      return handler.handle(
        SlashCommand(name: command, arguments: ''),
        spaceName: spaceName,
        senderJid: senderJid,
      );
    }

    // ---------------------------------------------------------------------------
    // /pause
    // ---------------------------------------------------------------------------

    group('/pause', () {
      test('no pauseController — returns service unavailable error', () async {
        final handler = buildHandler();
        final response = await invoke(handler, 'pause');
        expect(_isErrorCard(response), isTrue);
        expect(_errorSummary(response), contains('not configured'));
      });

      test('non-admin sender — returns permission denied error', () async {
        final controller = PauseController();
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'pause', senderJid: userJid);
        expect(_isErrorCard(response), isTrue);
        expect(_errorSummary(response), contains('admin'));
      });

      test('admin sender — pauses and returns confirmation', () async {
        final controller = PauseController();
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'pause');
        expect(controller.isPaused, isTrue);
        expect(_isConfirmationCard(response), isTrue);
        expect(_confirmationMessage(response), contains('paused'));
      });

      test('already paused — returns already-paused confirmation', () async {
        final controller = PauseController();
        controller.pause('alice');
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'pause');
        expect(_isConfirmationCard(response), isTrue);
        expect(_confirmationTitle(response), contains('Already Paused'));
      });
    });

    // ---------------------------------------------------------------------------
    // /resume
    // ---------------------------------------------------------------------------

    group('/resume', () {
      test('no pauseController — returns service unavailable error', () async {
        final handler = buildHandler();
        final response = await invoke(handler, 'resume');
        expect(_isErrorCard(response), isTrue);
      });

      test('non-admin sender — returns permission denied error', () async {
        final controller = PauseController()..pause('alice');
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'resume', senderJid: userJid);
        expect(_isErrorCard(response), isTrue);
        expect(controller.isPaused, isTrue); // still paused
      });

      test('not paused — returns not-paused confirmation', () async {
        final controller = PauseController();
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'resume');
        expect(_isConfirmationCard(response), isTrue);
        expect(_confirmationTitle(response), contains('Not Paused'));
      });

      test('admin sender — resumes and returns confirmation with count', () async {
        final controller = PauseController();
        controller.pause('alice');
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'resume');
        expect(controller.isPaused, isFalse);
        expect(_isConfirmationCard(response), isTrue);
        expect(_confirmationTitle(response), contains('Resumed'));
      });

      test('resume with queued messages — calls onDrain with collapsed map', () async {
        final controller = PauseController();
        controller.pause('alice');
        final fakeChannel = _FakeCh();
        controller.enqueue(
          ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'u@wa', text: 'hello'),
          fakeChannel,
          'session:1',
        );
        final handler = buildHandler(pauseController: controller);
        await invoke(handler, 'resume');
        expect(drainedSessions, hasLength(1));
        expect(drainedSessions.first.containsKey('session:1'), isTrue);
      });

      test('resume with 0 queued — confirmation says no messages queued', () async {
        final controller = PauseController()..pause('alice');
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'resume');
        expect(_confirmationMessage(response), contains('No messages'));
      });
    });

    // ---------------------------------------------------------------------------
    // /status with pause state
    // ---------------------------------------------------------------------------

    group('/status', () {
      test('shows pause section when paused', () async {
        final controller = PauseController()..pause('alice');
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'status');
        final sections = _getSections(response);
        final pauseSection = sections.firstWhere(
          (s) => (s['header'] as String?)?.contains('Agent Status') ?? false,
          orElse: () => <String, dynamic>{},
        );
        expect(pauseSection, isNotEmpty);
        expect(_sectionText(pauseSection), contains('PAUSED'));
      });

      test('no pause section when not paused', () async {
        final controller = PauseController();
        final handler = buildHandler(pauseController: controller);
        final response = await invoke(handler, 'status');
        final sections = _getSections(response);
        final pauseSection = sections.firstWhere(
          (s) => (s['header'] as String?)?.contains('Agent Status') ?? false,
          orElse: () => <String, dynamic>{},
        );
        expect(pauseSection, isEmpty);
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

bool _isErrorCard(Map<String, dynamic> response) {
  final cards = response['cardsV2'] as List<dynamic>?;
  if (cards == null || cards.isEmpty) return false;
  final card = (cards.first as Map)['card'] as Map<String, dynamic>;
  final header = card['header'] as Map<String, dynamic>?;
  return (header?['title'] as String?)?.contains('Error') == true ||
      (header?['title'] as String?)?.contains('Permission') == true ||
      (header?['title'] as String?)?.contains('Service Unavailable') == true ||
      (header?['title'] as String?)?.contains('Unavailable') == true;
}

String _errorSummary(Map<String, dynamic> response) {
  final cards = response['cardsV2'] as List<dynamic>;
  final card = (cards.first as Map)['card'] as Map<String, dynamic>;
  final sections = card['sections'] as List<dynamic>;
  for (final section in sections) {
    final widgets = (section as Map)['widgets'] as List<dynamic>;
    for (final w in widgets) {
      final text = (w as Map<String, dynamic>).values.whereType<Map<String, dynamic>>().map((m) => m['text'] as String? ?? '').join();
      if (text.isNotEmpty) return text;
    }
  }
  return '';
}

bool _isConfirmationCard(Map<String, dynamic> response) {
  final cards = response['cardsV2'] as List<dynamic>?;
  if (cards == null || cards.isEmpty) return false;
  return !_isErrorCard(response);
}

String _confirmationMessage(Map<String, dynamic> response) {
  final cards = response['cardsV2'] as List<dynamic>;
  final card = (cards.first as Map)['card'] as Map<String, dynamic>;
  final sections = card['sections'] as List<dynamic>;
  for (final section in sections) {
    final widgets = (section as Map)['widgets'] as List<dynamic>;
    for (final w in widgets) {
      final tp = (w as Map)['textParagraph'] as Map<String, dynamic>?;
      if (tp != null) return tp['text'] as String? ?? '';
    }
  }
  return '';
}

String _confirmationTitle(Map<String, dynamic> response) {
  final cards = response['cardsV2'] as List<dynamic>;
  final card = (cards.first as Map)['card'] as Map<String, dynamic>;
  final header = card['header'] as Map<String, dynamic>?;
  return header?['title'] as String? ?? '';
}

List<Map<String, dynamic>> _getSections(Map<String, dynamic> response) {
  final cards = response['cardsV2'] as List<dynamic>?;
  if (cards == null || cards.isEmpty) return [];
  final card = (cards.first as Map)['card'] as Map<String, dynamic>;
  return (card['sections'] as List<dynamic>).cast<Map<String, dynamic>>();
}

String _sectionText(Map<String, dynamic> section) {
  final widgets = (section['widgets'] as List<dynamic>).cast<Map<String, dynamic>>();
  final buffer = StringBuffer();
  for (final w in widgets) {
    final dt = w['decoratedText'] as Map<String, dynamic>?;
    if (dt != null) {
      buffer.write(dt['text'] ?? '');
      buffer.write(dt['topLabel'] ?? '');
    }
  }
  return buffer.toString();
}

class _FakeCh extends Channel {
  @override
  String get name => 'fake';
  @override
  ChannelType get type => ChannelType.whatsapp;

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendMessage(String recipientId, ChannelResponse response) async {}
}
