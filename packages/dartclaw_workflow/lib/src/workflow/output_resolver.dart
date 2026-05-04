/// Declares where a workflow output should be resolved from.
sealed class OutputResolver {
  /// Whether this resolver reads from authoritative ground truth.
  bool get authoritative;

  const OutputResolver();

  /// Serializes the resolver for tests and future DSL metadata.
  Map<String, Object?> toJson();

  /// Reconstructs an [OutputResolver] from [json].
  factory OutputResolver.fromJson(Map<String, Object?> json) {
    return switch (json['kind']) {
      'filesystem' => FileSystemOutput(
        pathPattern: json['pathPattern'] as String? ?? '**/*',
        listMode: json['listMode'] as bool? ?? false,
      ),
      'inline' => InlineOutput(schemaKey: json['schemaKey'] as String? ?? ''),
      'narrative' => NarrativeOutput(schemaKey: json['schemaKey'] as String? ?? ''),
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

  @override
  bool get authoritative => true;

  const FileSystemOutput({required this.pathPattern, required this.listMode});

  /// Returns true when [path] matches [pathPattern].
  bool matches(String path) => _globMatches(pathPattern, path);

  @override
  Map<String, Object?> toJson() => {'kind': 'filesystem', 'pathPattern': pathPattern, 'listMode': listMode};
}

/// Resolves non-path outputs directly from the inline workflow-context payload.
final class InlineOutput extends OutputResolver {
  /// Output field name this resolver belongs to.
  final String schemaKey;

  @override
  bool get authoritative => false;

  const InlineOutput({required this.schemaKey});

  @override
  Map<String, Object?> toJson() => {'kind': 'inline', 'schemaKey': schemaKey};
}

/// Resolves narrative outputs from inline payload first, then extraction turn.
final class NarrativeOutput extends OutputResolver {
  /// Output field name this resolver belongs to.
  final String schemaKey;

  @override
  bool get authoritative => false;

  const NarrativeOutput({required this.schemaKey});

  @override
  Map<String, Object?> toJson() => {'kind': 'narrative', 'schemaKey': schemaKey};
}

bool _globMatches(String pattern, String path) {
  final normalizedPattern = pattern.replaceAll(r'\', '/');
  final normalizedPath = path.replaceAll(r'\', '/');
  return RegExp(_globToRegex(normalizedPattern)).hasMatch(normalizedPath);
}

String _globToRegex(String pattern) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final char = pattern[i];
    if (char == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        if (i + 2 < pattern.length && pattern[i + 2] == '/') {
          buffer.write('(?:.*/)?');
          i += 2;
        } else {
          buffer.write('.*');
          i++;
        }
      } else {
        buffer.write('[^/]*');
      }
      continue;
    }
    if (char == '?') {
      buffer.write('[^/]');
      continue;
    }
    if (r'.+^$(){}|[]\'.contains(char)) {
      buffer.write(r'\');
    }
    buffer.write(char);
  }
  buffer.write(r'$');
  return buffer.toString();
}
