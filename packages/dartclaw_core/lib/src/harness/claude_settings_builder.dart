import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../container/container_executor.dart';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

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
/// stricter contract must add its own second-pass validation after calling this
/// builder.
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
    List<String>? declaredToolRules,
  }) {
    final settings = <String, dynamic>{};

    final baseSettings = options['settings'];
    switch (baseSettings) {
      case null:
        break;
      case final String raw:
        final trimmed = raw.trim();
        if (trimmed.isEmpty) break;
        // Derived step rules count as a structured key: taking the path-only
        // shortcut here would drop them and hand the CLI an empty policy.
        final hasStructured =
            options.containsKey('sandbox') || options.containsKey('permissions') || declaredToolRules != null;
        if (!hasStructured) {
          if (containerManager != null) {
            try {
              jsonDecode(trimmed);
            } on FormatException {
              return _containerSettingsPath(containerManager, hostWorkingDirectory, trimmed);
            }
          }
          return trimmed;
        }
        if (hasStructured) {
          if (declaredToolRules != null) {
            try {
              jsonDecode(trimmed);
            } on FormatException {
              // Merging into a settings *file* is not something this builder
              // can do, and silently returning the path would run the step on
              // the operator's policy with none of its declared rules — the
              // defect this derivation exists to close. Fail closed instead.
              throw StateError(
                'Claude provider options set "settings" to the path "$trimmed", which cannot carry a workflow '
                'step\'s declared tool policy. Inline the settings as JSON, or move the rules to '
                '"permissions", so the step runs on what it declared.',
              );
            }
          }
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
              final translated = _containerSettingsPath(containerManager, hostWorkingDirectory, trimmed);
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
    } else if (sandbox is String) {
      final block = _coarseSandboxBlock(sandbox);
      if (block != null) {
        _deepMergeInto(settings, {'sandbox': block});
      } else {
        _log.warning('Ignoring unsupported Claude sandbox value: "$sandbox"');
      }
    } else if (sandbox != null) {
      _log.warning('Ignoring unsupported Claude sandbox option type: ${sandbox.runtimeType}');
    }

    final permissions = options['permissions'];
    if (permissions is Map<dynamic, dynamic>) {
      _deepMergeInto(settings, {'permissions': normalizeDynamicMap(permissions)});
    } else if (permissions != null) {
      _log.warning('Ignoring unsupported Claude permissions option type: ${permissions.runtimeType}');
    }

    if (declaredToolRules != null) {
      final existing = settings['permissions'];
      final allow = <String>[
        if (existing is Map<String, dynamic> && existing['allow'] is List)
          ...(existing['allow'] as List).map((rule) => rule.toString()),
        ...declaredToolRules,
      ];
      _deepMergeInto(settings, {
        'permissions': {'allow': allow},
      });
    }

    if (settings.isEmpty) return null;
    return jsonEncode(settings);
  }

  /// Claude `permissions.allow` rules for the canonical tools a step declares.
  ///
  /// The step's declared tools are the policy the guard chain enforces; without
  /// these rules the CLI enforces its own, which is empty for a spawn that
  /// inherits nothing — so a declared `file_write` still had every `Write`
  /// refused while the operator's personal `Bash(…)` rules let shell commands
  /// through (observed live 2026-08-28). Same policy, stated to both layers.
  ///
  /// [writableRoots] scopes the file-mutating rules: the step's worktree and
  /// its artifacts directory, and nothing else. An unrecognised canonical name
  /// yields no rule — the CLI must never be widened by a name this mapping does
  /// not know, and the guard chain remains the inner boundary either way.
  ///
  /// `file_write` and `file_edit` both emit `Edit(...)`: the CLI checks file
  /// permissions against `Edit(path)` and `Read(path)` rules only, so a
  /// `Write(path)` rule is accepted and never consulted. Write-new and
  /// edit-existing are therefore one capability at the CLI, and the guard chain
  /// is where the finer distinction still lives. Paths are emitted with the
  /// `//` absolute anchor — a single leading slash anchors at the settings
  /// source, not the filesystem root — and a non-absolute root yields no rule.
  /// Both forms were verified live 2026-08-28: `Write(/abs/**)`,
  /// `Write(//abs/**)` and `Edit(/abs/**)` are all refused, `Edit(//abs/**)`
  /// writes.
  static List<String> allowRulesForCanonicalTools(
    Iterable<String> canonicalTools, {
    required Iterable<String> writableRoots,
  }) {
    final roots = writableRoots.map((root) => root.trim()).where((root) => p.isAbsolute(root)).toList();
    final rules = <String>[];
    for (final tool in canonicalTools) {
      switch (tool.trim()) {
        case 'shell':
          rules.add('Bash');
        case 'file_read':
          rules.add('Read');
        case 'file_write' || 'file_edit':
          rules.addAll(roots.map((root) => 'Edit(/${p.join(root, '**')})'));
        case 'web_fetch':
          rules.add('WebFetch');
        case 'web_search':
          rules.add('WebSearch');
        case 'mcp_call':
          rules.add('mcp__dartclaw');
      }
    }
    return rules.toSet().toList();
  }

  static String _containerSettingsPath(
    ContainerExecutor containerManager,
    String hostWorkingDirectory,
    String rawPath,
  ) {
    final hostPath = p.isAbsolute(rawPath) ? rawPath : p.normalize(p.join(hostWorkingDirectory, rawPath));
    final translated = containerManager.containerPathForHostPath(hostPath);
    if (translated == null) {
      throw StateError('Claude settings path is not mounted in the container: $hostPath');
    }
    return translated;
  }

  /// Translates a coarse DartClaw `sandbox` value into a Claude `sandbox`
  /// settings block, or `null` for an unrecognised value.
  ///
  /// This is the OS-isolation axis only — it never touches permission-mode.
  /// `workspace-write` leaves Claude's defaults (cwd + session temp writable);
  /// `read-only` denies all writes; `danger-full-access` disables the sandbox.
  ///
  /// Block keys (`enabled`, `allowUnsandboxedCommands`, `filesystem.denyWrite`)
  /// are the documented Claude sandbox schema — see
  /// https://code.claude.com/docs/en/sandboxing.md. `read-only` mirrors the
  /// docs' deny-all-writes pattern (`denyWrite: ["/"]`) and disables the
  /// unsandboxed-command escape hatch so reads stay enabled but writes cannot.
  static Map<String, dynamic>? _coarseSandboxBlock(String value) {
    return switch (value.trim()) {
      'danger-full-access' => {'enabled': false},
      'workspace-write' => {'enabled': true},
      'read-only' => {
        'enabled': true,
        'allowUnsandboxedCommands': false,
        'filesystem': {
          'denyWrite': ['/'],
        },
      },
      _ => null,
    };
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
