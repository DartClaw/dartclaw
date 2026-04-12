import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class SessionsListCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  SessionsListCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser
      ..addOption('type', help: 'Filter by session type')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List sessions';

  @override
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final sessions = await apiClient.getList(
        '/api/sessions',
        queryParameters: {'type': argResults!['type'] as String?},
      );
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, sessions);
        return;
      }
      if (sessions.isEmpty) {
        _writeLine('No sessions found.');
        return;
      }
      _writeLine('  ${'ID'.padRight(14)}  ${'TYPE'.padRight(10)}  ${'PROVIDER'.padRight(10)}  UPDATED');
      for (final raw in sessions) {
        final session = Map<String, dynamic>.from(raw as Map);
        final id = truncate(session['id']?.toString() ?? '', 14).padRight(14);
        final type = (session['type']?.toString() ?? '').padRight(10);
        final provider = (session['provider']?.toString() ?? '—').padRight(10);
        _writeLine('  $id  $type  $provider  ${formatDateTime(session['updatedAt'])}');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}
