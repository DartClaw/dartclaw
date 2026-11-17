/// One public registry origin and the container route that represents it.
typedef RegistryOrigin = ({Uri origin, String route});

/// Ecosystem knowledge for the host's read-only registry mirror.
abstract interface class RegistryAdapter {
  String get ecosystem;

  /// Ordered pins; the first is the package client's base registry.
  List<RegistryOrigin> get origins;

  Map<String, String> clientEnvironment(Uri mirrorBase);

  bool carriesMetadata(String path, String? contentType);
}
