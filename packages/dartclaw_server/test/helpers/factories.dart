import 'package:dartclaw_models/dartclaw_models.dart';

/// Creates a [Project] with sensible defaults for testing.
///
/// All fields are optional with defaults that produce a valid, ready project.
Project makeProject({
  String id = 'my-app',
  String name = 'My App',
  String remoteUrl = 'https://github.com/acme/repo.git',
  String localPath = '/data/projects/my-app',
  String defaultBranch = 'main',
  String? credentialsRef,
  CloneStrategy cloneStrategy = CloneStrategy.shallow,
  PrConfig pr = const PrConfig.defaults(),
  ProjectStatus status = ProjectStatus.ready,
  DateTime? lastFetchAt,
  bool configDefined = false,
  String? errorMessage,
  DateTime? createdAt,
}) {
  return Project(
    id: id,
    name: name,
    remoteUrl: remoteUrl,
    localPath: localPath,
    defaultBranch: defaultBranch,
    credentialsRef: credentialsRef,
    cloneStrategy: cloneStrategy,
    pr: pr,
    status: status,
    lastFetchAt: lastFetchAt,
    configDefined: configDefined,
    errorMessage: errorMessage,
    createdAt: createdAt ?? DateTime.parse('2026-01-01T00:00:00Z'),
  );
}
