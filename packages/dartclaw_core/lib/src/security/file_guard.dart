import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/path_utils.dart';
import 'guard.dart';
import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Access level for a protected file path.
enum FileAccessLevel { noAccess, readOnly, noDelete }

/// What a command/tool does to a file path.
enum FileOperation { read, write, delete }

// ---------------------------------------------------------------------------
// FileGuardRule
// ---------------------------------------------------------------------------

/// A single protection rule: glob pattern + access level.
class FileGuardRule {
  final String pattern;
  final FileAccessLevel level;

  const FileGuardRule({required this.pattern, required this.level});
}

// ---------------------------------------------------------------------------
// FileGuardConfig
// ---------------------------------------------------------------------------

/// Configuration for the file guard — protected path rules.
class FileGuardConfig {
  final List<FileGuardRule> rules;

  FileGuardConfig({required this.rules});

  /// Hardcoded default protections.
  factory FileGuardConfig.defaults() => FileGuardConfig(rules: [..._defaultRules]);

  /// Merges extra rules from YAML with defaults.
  factory FileGuardConfig.fromYaml(Map<String, dynamic> yaml) {
    final defaults = FileGuardConfig.defaults();
    final extraRules = <FileGuardRule>[];

    final rawRules = yaml['extra_rules'];
    if (rawRules is List) {
      for (final r in rawRules) {
        if (r is Map) {
          final pattern = r['pattern'];
          final levelStr = r['level'];
          if (pattern is String && levelStr is String) {
            final level = _parseLevel(levelStr);
            if (level != null) {
              extraRules.add(FileGuardRule(pattern: pattern, level: level));
            }
          }
        }
      }
    }

    return FileGuardConfig(rules: [...defaults.rules, ...extraRules]);
  }

  /// Adds self-protection for the given config file path.
  FileGuardConfig withSelfProtection(String configPath) {
    return FileGuardConfig(
      rules: [...rules, FileGuardRule(pattern: configPath, level: FileAccessLevel.readOnly)],
    );
  }

  static FileAccessLevel? _parseLevel(String s) {
    return switch (s) {
      'no_access' => FileAccessLevel.noAccess,
      'read_only' => FileAccessLevel.readOnly,
      'no_delete' => FileAccessLevel.noDelete,
      _ => null,
    };
  }

  static const _defaultRules = [
    // no_access — complete block
    FileGuardRule(pattern: '**/.ssh/**', level: FileAccessLevel.noAccess),
    FileGuardRule(pattern: '**/.ssh', level: FileAccessLevel.noAccess),
    FileGuardRule(pattern: '**/.gnupg/**', level: FileAccessLevel.noAccess),
    FileGuardRule(pattern: '**/.gnupg', level: FileAccessLevel.noAccess),
    FileGuardRule(pattern: '**/.aws/credentials', level: FileAccessLevel.noAccess),
    FileGuardRule(pattern: '**/.netrc', level: FileAccessLevel.noAccess),
    // read_only — block writes and deletes
    FileGuardRule(pattern: '**/.env', level: FileAccessLevel.readOnly),
    FileGuardRule(pattern: '**/.env.*', level: FileAccessLevel.readOnly),
    FileGuardRule(pattern: '**/*.pem', level: FileAccessLevel.readOnly),
    FileGuardRule(pattern: '**/*.key', level: FileAccessLevel.readOnly),
    FileGuardRule(pattern: '**/.kube/config', level: FileAccessLevel.readOnly),
    // no_delete — block deletes only
    FileGuardRule(pattern: '**/.gitconfig', level: FileAccessLevel.noDelete),
    FileGuardRule(pattern: '**/.bashrc', level: FileAccessLevel.noDelete),
    FileGuardRule(pattern: '**/.zshrc', level: FileAccessLevel.noDelete),
    FileGuardRule(pattern: '**/.profile', level: FileAccessLevel.noDelete),
  ];
}

// ---------------------------------------------------------------------------
// FileGuard
// ---------------------------------------------------------------------------

/// Glob-based file path protection guard.
///
/// Only evaluates on `beforeToolCall`. Handles Bash, write_file, and edit_file tools.
class FileGuard extends Guard {
  @override
  String get name => 'file';

  @override
  String get category => 'file';

  final FileGuardConfig config;

  FileGuard({FileGuardConfig? config}) : config = config ?? FileGuardConfig.defaults();

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (context.hookPoint != 'beforeToolCall') return GuardVerdict.pass();

    final toolName = context.toolName;
    final toolInput = context.toolInput;
    if (toolName == null || toolInput == null) return GuardVerdict.pass();

    final pathOps = switch (toolName) {
      'Bash' => _extractPathsFromBash(toolInput['command'] as String? ?? ''),
      'write_file' || 'edit_file' => _extractPathsFromTool(toolInput),
      _ => <_PathOp>[],
    };

    for (final po in pathOps) {
      final resolved = _resolvePath(po.path);
      final verdict = _checkAccess(resolved, po.operation);
      if (verdict != null) return verdict;
    }

    return GuardVerdict.pass();
  }

  // -------------------------------------------------------------------------
  // Path extraction
  // -------------------------------------------------------------------------

  List<_PathOp> _extractPathsFromTool(Map<String, dynamic> input) {
    final filePath = input['file_path'] as String?;
    if (filePath == null) return [];
    return [_PathOp(filePath, FileOperation.write)];
  }

  static final _redirectPattern = RegExp(r'(?:>>|>|2>>|2>|&>)\s*(\S+)');

  /// Classifies commands by their file operation type.
  static const _readCommands = {'cat', 'grep', 'head', 'tail', 'less', 'more', 'wc', 'file', 'stat', 'md5sum'};
  static const _writeCommands = {'tee', 'touch', 'chmod', 'chown', 'vi', 'vim', 'nano'};
  static const _deleteCommands = {'rm', 'unlink', 'rmdir'};

  List<_PathOp> _extractPathsFromBash(String command) {
    final results = <_PathOp>[];

    // Extract redirect targets (always write operations)
    for (final match in _redirectPattern.allMatches(command)) {
      final target = match.group(1);
      if (target != null && target != '/dev/null') {
        results.add(_PathOp(target, FileOperation.write));
      }
    }

    // Split on && ; || to get sub-commands
    final subCommands = command.split(RegExp(r'\s*(?:&&|;)\s*'));
    for (final sub in subCommands) {
      // Strip pipe chain — take only the first command in a pipe
      final pipeFirst = sub.split(RegExp(r'(?<!\|)\|(?!\|)')).first.trim();
      if (pipeFirst.isEmpty) continue;

      final tokens = pipeFirst.split(RegExp(r'\s+'));
      if (tokens.isEmpty) continue;

      // Handle sudo prefix
      var cmdIdx = 0;
      if (tokens[cmdIdx] == 'sudo' && tokens.length > 1) cmdIdx++;

      final cmd = tokens[cmdIdx];
      // Collect non-flag arguments as potential paths
      final args = <String>[];
      for (var i = cmdIdx + 1; i < tokens.length; i++) {
        if (!tokens[i].startsWith('-') || tokens[i] == '-') {
          args.add(tokens[i]);
        } else if ((tokens[i] == '-i' || tokens[i] == '--in-place') && cmd == 'sed') {
          // sed -i makes it a write operation
        }
      }

      if (_readCommands.contains(cmd)) {
        for (final a in args) {
          results.add(_PathOp(a, FileOperation.read));
        }
      } else if (_writeCommands.contains(cmd)) {
        for (final a in args) {
          results.add(_PathOp(a, FileOperation.write));
        }
      } else if (_deleteCommands.contains(cmd)) {
        for (final a in args) {
          results.add(_PathOp(a, FileOperation.delete));
        }
      } else if (cmd == 'sed') {
        // sed -i is write; sed without -i is read
        final isInPlace = pipeFirst.contains(RegExp(r'\s-i\b|--in-place'));
        final op = isInPlace ? FileOperation.write : FileOperation.read;
        for (final a in args) {
          // Skip the sed expression (first non-flag arg)
          if (a == args.first) continue;
          results.add(_PathOp(a, op));
        }
      } else if (cmd == 'cp' || cmd == 'mv') {
        // Source is read, destination is write
        if (args.length >= 2) {
          results.add(_PathOp(args.first, FileOperation.read));
          results.add(_PathOp(args.last, FileOperation.write));
        }
      }
    }

    return results;
  }

  // -------------------------------------------------------------------------
  // Path resolution + matching
  // -------------------------------------------------------------------------

  String _resolvePath(String path) {
    final expanded = expandHome(path);
    final normalized = p.normalize(expanded);
    // Resolve all symlinks in the path (including parent dirs like /var -> /private/var)
    try {
      final type = FileSystemEntity.typeSync(normalized, followLinks: true);
      if (type != FileSystemEntityType.notFound) {
        return File(normalized).resolveSymbolicLinksSync();
      }
    } catch (_) {
      // Non-existent path or permission error — use as-is
    }
    return normalized;
  }

  GuardVerdict? _checkAccess(String path, FileOperation operation) {
    // Find most restrictive matching rule
    FileAccessLevel? mostRestrictive;

    for (final rule in config.rules) {
      if (_globMatches(rule.pattern, path)) {
        if (mostRestrictive == null || rule.level.index < mostRestrictive.index) {
          mostRestrictive = rule.level;
        }
      }
    }

    if (mostRestrictive == null) return null;

    return switch (mostRestrictive) {
      FileAccessLevel.noAccess => GuardVerdict.block(
        'File access blocked: no_access on $path',
      ),
      FileAccessLevel.readOnly => switch (operation) {
        FileOperation.read => null,
        FileOperation.write => GuardVerdict.block('File access blocked: read_only (write) on $path'),
        FileOperation.delete => GuardVerdict.block('File access blocked: read_only (delete) on $path'),
      },
      FileAccessLevel.noDelete => switch (operation) {
        FileOperation.read || FileOperation.write => null,
        FileOperation.delete => GuardVerdict.block('File access blocked: no_delete on $path'),
      },
    };
  }

  /// Simple glob matching: `*` = any non-/ chars, `**` = any chars, `?` = single char.
  static bool _globMatches(String pattern, String path) {
    // Handle exact path match (for self-protection of config files)
    if (!pattern.contains('*') && !pattern.contains('?')) {
      // Resolve the pattern too (handles /var -> /private/var on macOS etc.)
      var resolved = pattern;
      try {
        final type = FileSystemEntity.typeSync(pattern, followLinks: true);
        if (type != FileSystemEntityType.notFound) {
          resolved = File(pattern).resolveSymbolicLinksSync();
        }
      } catch (_) {}
      return path == resolved || path.endsWith('/$resolved') || path.endsWith(p.separator + resolved);
    }

    // Convert glob to regex
    final buf = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      if (pattern[i] == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          // ** matches anything including /
          buf.write('.*');
          i += 2;
          // Skip trailing / after **
          if (i < pattern.length && pattern[i] == '/') i++;
          continue;
        }
        // * matches anything except /
        buf.write(r'[^/]*');
      } else if (pattern[i] == '?') {
        buf.write(r'[^/]');
      } else if (r'\.+^${}()|[]'.contains(pattern[i])) {
        buf.write(r'\');
        buf.write(pattern[i]);
      } else {
        buf.write(pattern[i]);
      }
      i++;
    }
    buf.write(r'$');

    final regex = RegExp(buf.toString());
    // Match against full path and also against path with leading /
    return regex.hasMatch(path) || regex.hasMatch(p.basename(path)) || _matchPathSuffix(regex, path);
  }

  /// Tries matching the pattern against all suffixes of the path.
  /// This handles patterns like `**/.env` matching `/home/user/.env`.
  static bool _matchPathSuffix(RegExp regex, String path) {
    final segments = path.split('/');
    for (var i = 0; i < segments.length; i++) {
      final suffix = segments.sublist(i).join('/');
      if (regex.hasMatch(suffix)) return true;
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

class _PathOp {
  final String path;
  final FileOperation operation;

  const _PathOp(this.path, this.operation);
}
