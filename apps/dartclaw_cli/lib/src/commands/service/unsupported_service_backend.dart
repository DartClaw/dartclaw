part of 'service_backend.dart';

class UnsupportedPlatformBackend implements ServiceBackend {
  static const _hint =
      'Automatic service management is not supported on this platform.\n'
      'Start DartClaw manually: dartclaw serve';

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    required ServiceScope scope,
    String? sourceDir,
    String? serviceUser,
  }) async => const ServiceResult(success: false, message: _hint);

  @override
  Future<ServiceResult> uninstall({required String instanceDir, required ServiceScope scope}) async =>
      const ServiceResult(success: false, message: _hint);

  @override
  Future<ServiceStatus> status({required String instanceDir, required ServiceScope scope}) async =>
      ServiceStatus.unknown;

  @override
  Future<ServiceResult> start({required String instanceDir, required ServiceScope scope}) async =>
      const ServiceResult(success: false, message: _hint);

  @override
  Future<ServiceResult> stop({required String instanceDir, required ServiceScope scope}) async =>
      const ServiceResult(success: false, message: _hint);
}
