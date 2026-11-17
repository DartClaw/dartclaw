import 'registry_adapter.dart';

final class NpmRegistryAdapter implements RegistryAdapter {
  new({Uri? upstream}) : origins = [(origin: upstream ?? Uri.https('registry.npmjs.org'), route: 'npm')];

  @override
  String get ecosystem => 'npm';

  @override
  final List<RegistryOrigin> origins;

  @override
  Map<String, String> clientEnvironment(Uri mirrorBase) => {
    'npm_config_registry': '$mirrorBase/npm',
    'npm_config_audit': 'false',
  };

  @override
  bool carriesMetadata(String path, String? contentType) => false;
}
