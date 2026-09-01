import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'credential_registry.dart';
import 'provider_identity.dart';
import 'providers_config.dart';

/// Validates provider binaries and credentials at startup.
class ProviderValidator {
  static final _log = Logger('ProviderValidator');

  /// Maximum time to wait for a binary probe (`--version` or `auth status`).
  static const _probeTimeout = Duration(seconds: 15);

  /// Probes the binary at [executable] by running `<executable> --version`.
  ///
  /// Returns the version string on success, or `null` on failure or timeout.
  static Future<String?> probeBinary(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']).timeout(_probeTimeout);
      if (result.exitCode != 0) {
        return null;
      }

      final stdoutText = processOutputToText(result.stdout);
      final stderrText = processOutputToText(result.stderr);
      return extractVersionLine(stdoutText, stderrText) ?? 'unknown';
    } on ProcessException {
      return null;
    } on TimeoutException {
      _log.warning("Provider probe timed out for '$executable'");
      return null;
    }
  }

  /// Probes whether the provider binary has its own authentication
  /// (OAuth/subscription), independent of an API key.
  ///
  /// For `claude`: runs `claude auth status` and checks `loggedIn`.
  /// For `codex`: checks `~/.codex/auth.json` for tokens.
  /// Returns `false` for unknown providers or on any error.
  ///
  /// [homePath] overrides `$HOME` for testing.
  static Future<bool> probeAuthStatus(String executable, {String? providerId, String? homePath}) async {
    final family = providerId != null ? ProviderIdentity.family(providerId) : null;

    // Codex: check auth.json file (no CLI status command available).
    if (family == ProviderIdentity.codex) {
      return _probeCodexAuthFile(homePath: homePath);
    }

    // Claude (and unknown): try `<executable> auth status`.
    return _probeClaudeAuthStatus(executable);
  }

  static Future<bool> _probeClaudeAuthStatus(String executable) async {
    try {
      final result = await Process.run(executable, ['auth', 'status']).timeout(_probeTimeout);
      if (result.exitCode != 0) return false;

      final stdoutText = processOutputToText(result.stdout);
      if (stdoutText.isEmpty) return false;

      final json = jsonDecode(stdoutText);
      return json is Map && json['loggedIn'] == true;
    } on ProcessException {
      return false;
    } on FormatException {
      return false;
    } on TimeoutException {
      _log.warning("Auth status probe timed out for '$executable'");
      return false;
    }
  }

  static bool _probeCodexAuthFile({String? homePath}) {
    try {
      final home = homePath ?? Platform.environment['HOME'];
      if (home == null || home.isEmpty) return false;

      final authFile = File('$home/.codex/auth.json');
      if (!authFile.existsSync()) return false;

      final json = jsonDecode(authFile.readAsStringSync());
      if (json is! Map) return false;

      // Codex stores OAuth tokens in a `tokens` map; accept a non-empty
      // string access_token as valid authentication.
      final tokens = json['tokens'];
      if (tokens is Map) {
        final accessToken = tokens['access_token'];
        if (accessToken is String && accessToken.isNotEmpty) return true;
      }

      // Also accept explicit API keys stored in the auth file. Newer Codex
      // exec automation guidance prefers CODEX_API_KEY, while older setups may
      // still persist OPENAI_API_KEY-compatible state.
      final storedKey = json['CODEX_API_KEY'] ?? json['OPENAI_API_KEY'];
      return storedKey is String && storedKey.trim().isNotEmpty;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  /// Validates all configured providers.
  ///
  /// Missing binary/credential entries for the default provider are errors;
  /// the same problems for secondary providers are warnings.
  ///
  /// Credentials resolve through [CredentialRegistry.resolve], so a provider is
  /// admitted on whichever credential `providers.<id>.auth` selects. When
  /// nothing is configured at all, the binary's own login (`claude auth status`,
  /// the Codex auth file) still counts — DartClaw presents nothing in that case,
  /// so there is no promise to break. A *forced* selection is never rescued that
  /// way: an absent forced credential refuses even with the other credential
  /// present and the CLI logged in.
  ///
  /// [isHostExecution] reports whether this deployment's resolved execution for
  /// a provider places it on the host. Container execution runs the CLI shipped
  /// in the image, so the host binary is not probed there, and it needs a
  /// host-presentable credential, so the binary's own login cannot stand in for
  /// one. It is a deployment-level answer, not a per-agent one — a container
  /// execution is refused at authority registration regardless. Defaults to
  /// host.
  ///
  /// [credentialsDir] is the dedicated subscription store this deployment
  /// resolved; passing it lets a refusal name the directory it searched, which
  /// is the only diagnostic that distinguishes "never stored" from "stored
  /// under a different `data_dir`".
  static Future<({List<String> errors, List<String> warnings})> validate({
    required ProvidersConfig providers,
    required CredentialRegistry registry,
    required String defaultProvider,
    String? homePath,
    String? credentialsDir,
    bool Function(String providerId)? isHostExecution,
  }) async {
    final errors = <String>[];
    final warnings = <String>[];
    final normalizedDefaultProvider = ProviderIdentity.normalize(defaultProvider);

    for (final entry in providers.entries.entries) {
      final providerId = entry.key;
      final provider = entry.value;
      final isDefaultProvider = ProviderIdentity.normalize(providerId) == normalizedDefaultProvider;

      // Container execution runs the CLI shipped in the image; the host binary
      // is not what runs, so its absence decides nothing.
      final hostExecution = isHostExecution?.call(providerId) ?? true;
      String? version;
      if (hostExecution) {
        version = await probeBinary(provider.executable);
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
      } else {
        _log.info("Provider '$providerId': container execution, host binary not probed");
      }

      if (provider.options['credentials_required'] == false) {
        continue;
      }

      final family = ProviderIdentity.resolveFamily(
        providerId,
        executable: provider.executable,
        options: provider.options,
      );
      final resolution = registry.resolve(providerId, family: family);
      if (resolution.isPresent) {
        continue;
      }

      // Only "nothing is configured" leaves room for the binary's own login: a
      // forced auth selection that cannot be satisfied must not be rescued by a
      // credential the operator did not choose.
      final reason = resolution.reason!;
      final rescuable = reason == CredentialUnavailableReason.noneConfigured && hostExecution;
      final binaryAuthed =
          rescuable &&
          version != null &&
          await probeAuthStatus(provider.executable, providerId: providerId, homePath: homePath);
      if (binaryAuthed) {
        _log.info("Provider '$providerId': using binary's own authentication");
      } else {
        // No 'Provider <id>:' prefix here: unlike the binary-probe message, the
        // remediation already opens by naming the provider.
        final message = credentialRemediationFor(
          reason,
          providerId: providerId,
          family: family,
          credentialsDir: credentialsDir,
        );
        if (isDefaultProvider) {
          errors.add(message);
        } else {
          warnings.add(message);
        }
      }
    }

    return (errors: errors, warnings: warnings);
  }
}

/// Converts a `Process.run` stdout/stderr value to a [String].
///
/// Handles `null`, raw `String`, `List<int>` (byte array), and arbitrary
/// objects via [Object.toString].
String processOutputToText(Object? value) {
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

/// Returns the first non-empty trimmed line from the combined stdout and
/// stderr output, or `null` if both are empty.
String? extractVersionLine(String stdoutText, String stderrText) {
  for (final line in '$stdoutText\n$stderrText'.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return null;
}
