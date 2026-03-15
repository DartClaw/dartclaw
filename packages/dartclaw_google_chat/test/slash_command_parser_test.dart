import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  group('SlashCommandParser.parseFromMessage', () {
    const parser = SlashCommandParser();

    test('parses slash commands from MESSAGE metadata', () {
      final command = parser.parseFromMessage({
        'message': {
          'slashCommand': {'commandId': 1},
          'argumentText': 'research: analyze competitor pricing',
          'text': '/new research: analyze competitor pricing',
        },
      });

      expect(command, isNotNull);
      expect(command!.name, 'new');
      expect(command.arguments, 'research: analyze competitor pricing');
    });

    test('parses string command IDs', () {
      final command = parser.parseFromMessage({
        'message': {
          'slashCommand': {'commandId': '2'},
          'text': '/reset',
        },
      });

      expect(command, isNotNull);
      expect(command!.name, 'reset');
      expect(command.arguments, isEmpty);
    });

    test('falls back to message text when argumentText is absent', () {
      final command = parser.parseFromMessage({
        'message': {
          'slashCommand': {'commandId': 1},
          'text': '/new writing: draft release notes',
        },
      });

      expect(command, isNotNull);
      expect(command!.name, 'new');
      expect(command.arguments, 'writing: draft release notes');
    });

    test('falls back to explicit command names when commandId is missing', () {
      final command = parser.parseFromMessage({
        'message': {
          'slashCommand': {'commandName': '/foo'},
          'argumentText': 'bar baz',
        },
      });

      expect(command, isNotNull);
      expect(command!.name, 'foo');
      expect(command.arguments, 'bar baz');
    });

    test('parses slash commands from MESSAGE annotations when message.slashCommand is absent', () {
      final command = parser.parseFromMessage({
        'message': {
          'annotations': [
            {
              'type': 'SLASH_COMMAND',
              'slashCommand': {'commandId': 3},
            },
          ],
          'text': '/status',
        },
      });

      expect(command, isNotNull);
      expect(command!.name, 'status');
      expect(command.arguments, isEmpty);
    });

    test('returns synthetic names for unknown numeric MESSAGE command IDs', () {
      final command = parser.parseFromMessage({
        'message': {
          'slashCommand': {'commandId': 99},
          'text': '/mystery',
        },
      });

      expect(command, isNotNull);
      expect(command!.name, 'unknown_99');
      expect(command.arguments, isEmpty);
    });

    test('returns null when slash command metadata is missing', () {
      expect(
        parser.parseFromMessage({
          'message': {'text': 'hello'},
        }),
        isNull,
      );
    });
  });

  group('SlashCommandParser.parseFromAppCommand', () {
    test('parses APP_COMMAND payloads using appCommandId', () {
      const parser = SlashCommandParser();
      final command = parser.parseFromAppCommand({
        'appCommandMetadata': {'appCommandId': 3},
        'message': {'argumentText': ''},
      });

      expect(command, isNotNull);
      expect(command!.name, 'status');
      expect(command.arguments, isEmpty);
    });

    test('falls back to commandId when appCommandId is absent', () {
      const parser = SlashCommandParser(commandIdMap: {7: 'sync'});
      final command = parser.parseFromAppCommand({
        'appCommandMetadata': {'commandId': 7},
        'message': {'argumentText': 'now'},
      });

      expect(command, isNotNull);
      expect(command!.name, 'sync');
      expect(command.arguments, 'now');
    });

    test('prefers appCommandId when both APP_COMMAND ID fields are present', () {
      const parser = SlashCommandParser();
      final command = parser.parseFromAppCommand({
        'appCommandMetadata': {'appCommandId': 3, 'commandId': 1},
        'message': {'argumentText': ''},
      });

      expect(command, isNotNull);
      expect(command!.name, 'status');
    });

    test('returns synthetic names for unknown numeric APP_COMMAND IDs', () {
      const parser = SlashCommandParser();
      final command = parser.parseFromAppCommand({
        'appCommandMetadata': {'appCommandId': 42},
        'message': {'argumentText': ''},
      });

      expect(command, isNotNull);
      expect(command!.name, 'unknown_42');
      expect(command.arguments, isEmpty);
    });

    test('returns null when metadata is missing', () {
      const parser = SlashCommandParser();
      expect(parser.parseFromAppCommand(const {}), isNull);
    });
  });
}
