import 'dart:io';

import 'package:logging/logging.dart';

import 'credential_registry.dart';
import 'provider_identity.dart';
import 'providers_config.dart';

/// Validates provider binaries and credentials at startup.
class ProviderValidator {
  static final _log = Logger('ProviderValidator');

  /// Probes the binary at [executable] by running `<executable> --version`.
  ///
  /// Returns the version string on success, or `null` on failure.
  static Future<String?> probeBinary(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']);
      if (result.exitCode != 0) {
        return null;
      }

      final stdoutText = _toText(result.stdout);
      final stderrText = _toText(result.stderr);
      return _extractVersion(stdoutText, stderrText) ?? 'unknown';
    } on ProcessException {
      return null;
    }
  }

  /// Validates all configured providers.
  ///
  /// Missing binary/credential entries for the default provider are errors;
  /// the same problems for secondary providers are warnings.
  static Future<({List<String> errors, List<String> warnings})> validate({
    required ProvidersConfig providers,
    required CredentialRegistry registry,
    required String defaultProvider,
  }) async {
    final errors = <String>[];
    final warnings = <String>[];
    final normalizedDefaultProvider = ProviderIdentity.normalize(defaultProvider);

    for (final entry in providers.entries.entries) {
      final providerId = entry.key;
      final provider = entry.value;
      final isDefaultProvider = ProviderIdentity.normalize(providerId) == normalizedDefaultProvider;

      final version = await probeBinary(provider.executable);
      if (version == null) {
        final message = "Provider '$providerId': binary not found at '${provider.executable}'";
        if (isDefaultProvider) {
          errors.add(message);
        } else {
          warnings.add(message);
        }
      } else {
        _log.info("Provider '$providerId': binary version $version");
      }

      if (!registry.hasCredential(providerId)) {
        final envVar = CredentialRegistry.envVarFor(providerId);
        final message = envVar == null
            ? "Provider '$providerId': credentials not configured (set API key or add to credentials section)"
            : "Provider '$providerId': credentials not configured (set $envVar or add to credentials section)";
        if (isDefaultProvider) {
          errors.add(message);
        } else {
          warnings.add(message);
        }
      }
    }

    return (errors: errors, warnings: warnings);
  }

  static String _toText(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value;
    }
    if (value is List<int>) {
      return String.fromCharCodes(value);
    }
    return value.toString();
  }

  static String? _extractVersion(String stdoutText, String stderrText) {
    for (final line in '$stdoutText\n$stderrText'.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }
}
