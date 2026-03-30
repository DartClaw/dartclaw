import 'package:logging/logging.dart';

import 'google_chat_utils.dart' as utils;

/// Parsed slash command from a Google Chat event payload.
class SlashCommand {
  /// Slash command name without the leading `/`.
  final String name;

  /// Raw argument text with the command prefix removed.
  final String arguments;

  /// Creates an immutable parsed slash command.
  const SlashCommand({required this.name, required this.arguments});
}

/// Extracts Google Chat slash commands from webhook event payloads.
///
/// Supports both documented event shapes:
/// - `MESSAGE` with `message.slashCommand`
/// - `APP_COMMAND` with `appCommandMetadata`
class SlashCommandParser {
  static final _log = Logger('SlashCommandParser');

  /// Known Google Chat command IDs mapped to command names.
  final Map<int, String> commandIdMap;

  /// Creates a slash command parser with an optional command ID mapping.
  const SlashCommandParser({
    this.commandIdMap = const {1: 'new', 2: 'reset', 3: 'status', 4: 'stop', 5: 'pause', 6: 'resume'},
  });

  /// Parses a slash command from a `MESSAGE` event payload.
  SlashCommand? parseFromMessage(Map<String, dynamic> payload) {
    final message = utils.asMap(payload['message']);
    if (message == null) {
      return null;
    }

    final directSlashCommand = utils.asMap(message['slashCommand']);
    final slashCommand = directSlashCommand ?? _findSlashCommandAnnotation(message);
    if (slashCommand == null) {
      return null;
    }

    final commandName = _resolveCommandName(slashCommand);
    if (commandName == null) {
      _log.fine('Ignoring Google Chat MESSAGE slash command with unknown metadata: $slashCommand');
      return null;
    }

    final sourceShape = directSlashCommand != null
        ? 'MESSAGE+message.slashCommand'
        : 'MESSAGE+message.annotations[].slashCommand';
    _log.fine('Parsed Google Chat slash command from $sourceShape: /$commandName');
    return SlashCommand(name: commandName, arguments: _extractArguments(message));
  }

  /// Parses a slash command from an `APP_COMMAND` event payload.
  SlashCommand? parseFromAppCommand(Map<String, dynamic> payload) {
    final appCommandMetadata = utils.asMap(payload['appCommandMetadata']);
    if (appCommandMetadata == null) {
      return null;
    }

    final commandName = _resolveCommandName(appCommandMetadata, idKeys: const ['appCommandId', 'commandId']);
    if (commandName == null) {
      _log.fine('Ignoring Google Chat APP_COMMAND with unknown metadata: $appCommandMetadata');
      return null;
    }

    final message = utils.asMap(payload['message']);
    _log.fine('Parsed Google Chat slash command from APP_COMMAND shape: /$commandName');
    return SlashCommand(name: commandName, arguments: message == null ? '' : _extractArguments(message));
  }

  String? _resolveCommandName(Map<String, dynamic> metadata, {List<String> idKeys = const ['commandId']}) {
    for (final idKey in idKeys) {
      if (!metadata.containsKey(idKey)) {
        continue;
      }

      final fromId = _resolveCommandNameFromId(metadata[idKey]);
      if (fromId != null) {
        return fromId;
      }
    }

    final explicitName = metadata['commandName'];
    if (explicitName is! String) {
      return null;
    }

    final normalized = explicitName.trim().replaceFirst(RegExp(r'^/+'), '').toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  String? _resolveCommandNameFromId(Object? commandId) {
    final parsedCommandId = _parseCommandId(commandId);
    if (parsedCommandId == null) {
      return null;
    }

    return commandIdMap[parsedCommandId] ?? 'unknown_$parsedCommandId';
  }

  String _extractArguments(Map<String, dynamic> message) {
    final argumentText = message['argumentText'];
    if (argumentText is String) {
      return argumentText.trim();
    }

    final text = message['text'];
    if (text is! String) {
      return '';
    }

    final trimmed = text.trim();
    final firstSpace = trimmed.indexOf(' ');
    if (firstSpace <= 0) {
      return '';
    }
    return trimmed.substring(firstSpace + 1).trim();
  }

  Map<String, dynamic>? _findSlashCommandAnnotation(Map<String, dynamic> message) {
    final annotations = message['annotations'];
    if (annotations is! List) {
      return null;
    }

    for (final annotation in annotations) {
      final annotationMap = utils.asMap(annotation);
      final slashCommand = utils.asMap(annotationMap?['slashCommand']);
      if (slashCommand != null) {
        return slashCommand;
      }
    }

    return null;
  }

  int? _parseCommandId(Object? commandId) {
    if (commandId is int) {
      return commandId;
    }
    if (commandId is String) {
      return int.tryParse(commandId);
    }
    return null;
  }
}
