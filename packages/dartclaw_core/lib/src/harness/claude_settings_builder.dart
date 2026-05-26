import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../container/container_executor.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show normalizeDynamicMap;

final _log = Logger('ClaudeSettingsBuilder');

/// Builds the Claude CLI `--settings` JSON payload and resolves the
/// `permissionMode` option from provider options maps.
///
/// This is a pure-utility class: no process I/O, no `dart:io` imports.
/// Callers that need the final JSON string for the `--settings` CLI argument
/// receive it as the return value of [buildSettings]; the builder never calls
/// [jsonEncode] on the caller's behalf for any other path.
///
/// **Permission-mode policy**: [buildPermissionMode] accepts the full canonical
/// set of Claude permission-mode values (`acceptEdits`, `auto`,
/// `bypassPermissions`, `default`, `dontAsk`, `plan`). Callers that need a
/// stricter contract (e.g. workflow one-shot mode, which cannot block waiting
/// for interactive approval) must add their own second-pass validation after
/// calling this builder.
abstract final class ClaudeSettingsBuilder {
  /// Parses the `permissionMode` key from [options] and validates it against
  /// the canonical Claude permission-mode set.
  ///
  /// Returns `null` when the key is absent or blank. Throws [StateError] for
  /// unsupported types or unrecognised mode strings.
  static String? buildPermissionMode(Map<String, dynamic> options) {
    final raw = options['permissionMode'];
    if (raw == null) return null;
    if (raw is! String) {
      throw StateError('Unsupported Claude permissionMode "${raw.runtimeType}"');
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    const allowed = {'acceptEdits', 'auto', 'bypassPermissions', 'default', 'dontAsk', 'plan'};
    if (!allowed.contains(trimmed)) {
      throw StateError('Unsupported Claude permissionMode "$trimmed"');
    }
    return trimmed;
  }

  /// Builds the settings payload for the Claude CLI `--settings` argument.
  ///
  /// Merges the `settings`, `sandbox`, and `permissions` sub-keys from
  /// [options] into a single JSON-encoded string. When the `settings` value is
  /// a plain path string (not JSON) *and* no structured `sandbox`/`permissions`
  /// keys are present, returns the path directly (the caller must pass it
  /// verbatim to the CLI).
  ///
  /// Returns `null` when no settings-related keys are present in [options].
  ///
  /// [containerManager] and [hostWorkingDirectory] are used only to translate
  /// host-filesystem paths to container-relative paths when the `settings`
  /// value is a file path. Both are optional — pass `null` when running
  /// outside a container.
  static String? buildSettings(
    Map<String, dynamic> options, {
    required ContainerExecutor? containerManager,
    required String hostWorkingDirectory,
  }) {
    final settings = <String, dynamic>{};

    final baseSettings = options['settings'];
    switch (baseSettings) {
      case null:
        break;
      case final String raw:
        final trimmed = raw.trim();
        if (trimmed.isEmpty) break;
        if (!options.containsKey('sandbox') && !options.containsKey('permissions')) {
          if (containerManager != null) {
            try {
              jsonDecode(trimmed);
            } on FormatException {
              final hostPath = p.isAbsolute(trimmed) ? trimmed : p.normalize(p.join(hostWorkingDirectory, trimmed));
              final translated = containerManager.containerPathForHostPath(hostPath);
              if (translated == null) {
                throw StateError('Claude settings path is not mounted in the container: $hostPath');
              }
              return translated;
            }
          }
          return trimmed;
        }
        if (options.containsKey('sandbox') || options.containsKey('permissions')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map<String, dynamic>) {
              settings.addAll(decoded);
              break;
            }
            if (decoded is Map<dynamic, dynamic>) {
              settings.addAll(normalizeDynamicMap(decoded));
              break;
            }
            _log.warning(
              'Claude provider options include raw "settings" plus structured "sandbox"/"permissions", '
              'but the raw settings JSON is not an object; structured settings are ignored.',
            );
            return trimmed;
          } on FormatException {
            if (containerManager != null) {
              final hostPath = p.isAbsolute(trimmed) ? trimmed : p.normalize(p.join(hostWorkingDirectory, trimmed));
              final translated = containerManager.containerPathForHostPath(hostPath);
              if (translated == null) {
                throw StateError('Claude settings path is not mounted in the container: $hostPath');
              }
              _log.warning(
                'Claude provider options include settings path "$trimmed" plus structured '
                '"sandbox"/"permissions"; structured settings are ignored for path-based settings.',
              );
              return translated;
            }
            _log.warning(
              'Claude provider options include settings path "$trimmed" plus structured '
              '"sandbox"/"permissions"; structured settings are ignored for path-based settings.',
            );
            return trimmed;
          }
        }
        return trimmed;
      case final Map<dynamic, dynamic> rawMap:
        settings.addAll(normalizeDynamicMap(rawMap));
      default:
        _log.warning('Ignoring unsupported Claude settings option type: ${baseSettings.runtimeType}');
    }

    final sandbox = options['sandbox'];
    if (sandbox is Map<dynamic, dynamic>) {
      _deepMergeInto(settings, {'sandbox': normalizeDynamicMap(sandbox)});
    } else if (sandbox != null) {
      _log.warning('Ignoring unsupported Claude sandbox option type: ${sandbox.runtimeType}');
    }

    final permissions = options['permissions'];
    if (permissions is Map<dynamic, dynamic>) {
      _deepMergeInto(settings, {'permissions': normalizeDynamicMap(permissions)});
    } else if (permissions != null) {
      _log.warning('Ignoring unsupported Claude permissions option type: ${permissions.runtimeType}');
    }

    if (settings.isEmpty) return null;
    return jsonEncode(settings);
  }

  static void _deepMergeInto(Map<String, dynamic> target, Map<String, dynamic> overlay) {
    for (final entry in overlay.entries) {
      final existing = target[entry.key];
      final incoming = entry.value;
      if (existing is Map<String, dynamic> && incoming is Map<String, dynamic>) {
        _deepMergeInto(existing, incoming);
      } else {
        target[entry.key] = incoming;
      }
    }
  }
}
