import 'package:path/path.dart' as p;

/// Structural content types supported by [ExplorationSummarizer].
enum ContentType { json, yaml, csv, tsv, dart, typescript, python, go }

/// Detects the structural type of content for exploration summaries.
///
/// Uses file extension (primary) when a file hint is available, and falls back
/// to content heuristics for extensionless or misnamed files. Returns null for
/// unrecognized content.
abstract final class TypeDetector {
  /// Detect content type from [fileHint] extension (primary) or
  /// [content] heuristics (fallback). Returns null if unrecognized.
  static ContentType? detect(String content, {String? fileHint}) {
    if (fileHint != null) {
      final type = _fromExtension(p.extension(fileHint).toLowerCase());
      if (type != null) return type;
    }
    return _fromHeuristics(content);
  }

  static ContentType? _fromExtension(String ext) {
    return switch (ext) {
      '.json' => ContentType.json,
      '.yaml' || '.yml' => ContentType.yaml,
      '.csv' => ContentType.csv,
      '.tsv' => ContentType.tsv,
      '.dart' => ContentType.dart,
      '.ts' || '.tsx' || '.js' || '.jsx' || '.mjs' || '.cjs' => ContentType.typescript,
      '.py' || '.pyi' => ContentType.python,
      '.go' => ContentType.go,
      _ => null,
    };
  }

  static ContentType? _fromHeuristics(String content) {
    final trimmed = content.trimLeft();
    if (trimmed.isEmpty) return null;

    // JSON: starts with { or [
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return ContentType.json;
    }

    // Check first two lines for TSV/CSV (need at least header + data row for confidence)
    final lines = trimmed.split('\n');
    final firstLine = lines.first;
    final secondLine = lines.length > 1 ? lines[1] : '';

    if (firstLine.contains('\t') &&
        firstLine.split('\t').length > 1 &&
        secondLine.contains('\t') &&
        secondLine.split('\t').length > 1) {
      return ContentType.tsv;
    }

    // CSV: require at least 2 lines with the same column count of comma-separated values.
    // This avoids matching ordinary prose that happens to contain commas.
    if (secondLine.isNotEmpty && firstLine.contains(',') && secondLine.contains(',')) {
      final headerCols = firstLine.split(',').length;
      final dataCols = secondLine.split(',').length;
      if (headerCols >= 2 && headerCols == dataCols) {
        // Avoid matching source code (no braces, parens, assignment operators in field names)
        final headerParts = firstLine.split(',');
        final looksLikeCsv = headerParts.every((p) {
          final t = p.trim();
          return t.isNotEmpty && !t.contains('{') && !t.contains('(') && !t.contains('=') && !t.contains(';');
        });
        if (looksLikeCsv) return ContentType.csv;
      }
    }

    // TypeScript/JS: check before Dart because 'export' appears in both.
    // Dart exports are always `export 'uri'`, never `export interface/type/class`.
    // TypeScript: export/import with from keyword, or standalone interface/type/enum declarations.
    final tsPattern = RegExp(r'^(export|import)\s.+from\s|^(export\s+)?(interface|type|enum)\s+\w', multiLine: true);
    if (tsPattern.hasMatch(content)) return ContentType.typescript;

    // Python: check before Dart because `class` appears in both.
    // Python classes and functions end with `:`, Dart classes use `{`.
    // Python `from x import y` and `def x(` are unambiguous.
    final pyPattern = RegExp(r'^(def |from .+ import )', multiLine: true);
    if (pyPattern.hasMatch(content)) return ContentType.python;

    // Python class: `class Name:` (colon at end after optional parens — Dart uses `{`)
    if (RegExp(r'^class \w+.*:\s*$', multiLine: true).hasMatch(content)) {
      return ContentType.python;
    }

    // Dart: common top-level keywords at line start.
    // Dart imports/exports always use quoted URIs — this distinguishes them from TS/JS imports.
    final dartPattern = RegExp(
      // Class/mixin/enum/extension/typedef declarations
      r'^(abstract\s+class|(?:base|final|sealed|interface)\s+class|class|mixin|enum|extension|typedef)\s+\w'
      // Import/export/part with quoted URIs (Dart-style)
      '|^import\\s+[\'"]|^export\\s+[\'"]|^library\\s+\\w|^part\\s+[\'"]',
      multiLine: true,
    );
    if (dartPattern.hasMatch(content)) return ContentType.dart;

    // Go: package, func, type struct
    final goPattern = RegExp(r'^(package |func |type \w+ struct|type \w+ interface)', multiLine: true);
    if (goPattern.hasMatch(content)) return ContentType.go;

    // YAML: multiple lines with `key: value` pattern (no braces, not code).
    // Check at least 3 matching lines to reduce false positives.
    if (lines.length >= 3) {
      final yamlLinePattern = RegExp(r'^[\w][\w.\-]*\s*:');
      var yamlMatches = 0;
      for (final line in lines.take(10)) {
        if (yamlLinePattern.hasMatch(line)) yamlMatches++;
      }
      if (yamlMatches >= 3) return ContentType.yaml;
    }

    return null;
  }
}
