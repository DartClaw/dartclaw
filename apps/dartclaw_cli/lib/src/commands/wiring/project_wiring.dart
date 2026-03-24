import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show DartclawConfig, EventBus, ProjectService;
import 'package:dartclaw_server/dartclaw_server.dart' show ProjectServiceImpl;
import 'package:logging/logging.dart';

/// Constructs and exposes the project management service.
class ProjectWiring {
  ProjectWiring({
    required this.config,
    required String dataDir,
    required EventBus eventBus,
  })  : _dataDir = dataDir,
        _eventBus = eventBus;

  final DartclawConfig config;
  final String _dataDir;
  final EventBus _eventBus;

  static final _log = Logger('ProjectWiring');

  late ProjectServiceImpl _projectService;

  ProjectService get projectService => _projectService;

  Future<void> wire() async {
    // Ensure the clones directory exists.
    final clonesDir = Directory(config.projectsClonesDir);
    if (!clonesDir.existsSync()) {
      clonesDir.createSync(recursive: true);
      _log.fine('Created projects clones directory: ${config.projectsClonesDir}');
    }

    _projectService = ProjectServiceImpl(
      dataDir: _dataDir,
      projectConfig: config.projects,
      credentials: config.credentials,
      eventBus: _eventBus,
    );

    await _projectService.initialize();
  }

  Future<void> dispose() async {
    await _projectService.dispose();
  }
}
