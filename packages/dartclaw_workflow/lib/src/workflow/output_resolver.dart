import 'package:dartclaw_kernel/dartclaw_kernel.dart' show globToRegex;

/// Declares where a workflow output should be resolved from.
sealed class OutputResolver {
  const new();

  /// Serializes the resolver for tests and future DSL metadata.
  Map<String, Object?> toJson();

  /// Reconstructs an [OutputResolver] from [json].
  factory fromJson(Map<String, Object?> json) {
    return switch (json['kind']) {
      'filesystem' => FileSystemOutput(
        pathPattern: json['pathPattern'] as String? ?? '**/*',
        listMode: json['listMode'] as bool? ?? false,
        preferPatterns: (json['preferPatterns'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      ),
      'inline' => InlineOutput(schemaKey: json['schemaKey'] as String? ?? ''),
      'narrative' => InlineOutput(schemaKey: json['schemaKey'] as String? ?? ''),
      final kind => throw FormatException('Unknown output resolver kind "$kind"'),
    };
  }
}

/// Resolves path-shaped outputs from files changed in the task worktree.
final class FileSystemOutput extends OutputResolver {
  /// Glob-like path pattern matched against worktree-relative paths.
  final String pathPattern;

  /// Whether the output expects multiple matching paths.
  final bool listMode;

  /// Ordered basename preferences that pick a single winner when the worktree
  /// diff yields multiple matches for a non-list output.
  ///
  /// Each entry is a bare basename compared case-insensitively; the first entry
  /// with exactly one matching candidate wins. Empty means no preference (a
  /// multi-match then surfaces as an ambiguity failure). This is the generic,
  /// declarative replacement for hard-coded framework basenames in the engine.
  final List<String> preferPatterns;

  const new({required this.pathPattern, required this.listMode, this.preferPatterns = const []});

  /// Returns true when [path] matches [pathPattern].
  bool matches(String path) => _globMatches(pathPattern, path);

  @override
  Map<String, Object?> toJson() => {
    'kind': 'filesystem',
    'pathPattern': pathPattern,
    'listMode': listMode,
    if (preferPatterns.isNotEmpty) 'preferPatterns': preferPatterns,
  };
}

/// Resolves non-path outputs directly from the execution envelope's `outputs`.
final class InlineOutput extends OutputResolver {
  /// Output field name this resolver belongs to.
  final String schemaKey;

  const new({required this.schemaKey});

  @override
  Map<String, Object?> toJson() => {'kind': 'inline', 'schemaKey': schemaKey};
}

bool _globMatches(String pattern, String path) {
  final normalizedPattern = pattern.replaceAll(r'\', '/');
  final normalizedPath = path.replaceAll(r'\', '/');
  return RegExp(globToRegex(normalizedPattern)).hasMatch(normalizedPath);
}
