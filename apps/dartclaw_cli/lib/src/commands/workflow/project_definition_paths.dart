import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:path/path.dart' as p;

String configuredProjectDirectory(DartclawConfig config, ProjectDefinition definition) {
  return definition.localPath ?? p.join(config.projectsClonesDir, definition.id);
}

List<String> configuredProjectDirectories(DartclawConfig config) {
  return config.projects.definitions.values
      .map((definition) => configuredProjectDirectory(config, definition))
      .toList();
}
