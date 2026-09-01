import 'slash_command_parser.dart';

/// Executes a Google Chat slash command through runtime-owned services.
abstract interface class SlashCommandExecutor {
  /// Executes [command] and returns a Cards v2 webhook response payload.
  Future<Map<String, dynamic>> handle(
    SlashCommand command, {
    required String spaceName,
    required String senderJid,
    String? senderDisplayName,
    String? spaceType,
    String? sourceMessageId,
  });
}
