import 'registry_adapter.dart';

final class PubRegistryAdapter implements RegistryAdapter {
  new({Uri? upstream}) : origins = [(origin: upstream ?? Uri.https('pub.dev'), route: 'pub')];

  @override
  String get ecosystem => 'pub';

  @override
  final List<RegistryOrigin> origins;

  @override
  Map<String, String> clientEnvironment(Uri mirrorBase) => {'PUB_HOSTED_URL': '$mirrorBase/pub'};

  @override
  bool carriesMetadata(String path, String? contentType) =>
      path.startsWith('/api/packages/') && contentType?.split(';').first.trim() == 'application/json';
}
