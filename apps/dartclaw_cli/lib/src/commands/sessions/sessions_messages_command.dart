import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class SessionsMessagesCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  SessionsMessagesCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser
      ..addOption('limit', help: 'Maximum number of messages to show')
      ..addFlag('full', negatable: false, help: 'Print full message content')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'messages';

  @override
  String get description => 'Show session messages';

  @override
  Future<void> run() async {
    final sessionId = _requireSessionId();
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final messages = await apiClient.getList('/api/sessions/$sessionId/messages');
      final limit = int.tryParse((argResults!['limit'] as String?) ?? '');
      final visible = limit == null || limit >= messages.length
          ? messages
          : messages.take(limit).toList(growable: false);
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, visible);
        return;
      }
      final full = argResults!['full'] as bool;
      for (final raw in visible) {
        final message = Map<String, dynamic>.from(raw as Map);
        final role = (message['role']?.toString() ?? 'unknown').padRight(10);
        final content = message['content']?.toString() ?? '';
        _writeLine('$role ${full ? content : truncate(content, 100)}');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  String _requireSessionId() {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Session ID required', usage);
    }
    return args.first;
  }
}
