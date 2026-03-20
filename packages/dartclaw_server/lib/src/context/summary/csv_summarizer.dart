/// Extracts column info and samples from CSV/TSV content.
abstract final class CsvSummarizer {
  /// Returns a formatted column + sample summary or null on parse failure.
  static String? summarize(String content, int estimatedTokens, {String delimiter = ','}) {
    try {
      return _summarize(content, estimatedTokens, delimiter);
    } catch (_) {
      return null;
    }
  }

  static String? _summarize(String content, int estimatedTokens, String delimiter) {
    final lines = content.split('\n').where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;

    final headers = _splitLine(lines.first, delimiter);
    if (headers.length < 2) return null; // Not a valid CSV

    final dataLines = lines.skip(1).toList();
    final rowCount = dataLines.length;

    // Parse up to 10 rows to infer types
    final sampleRows = <List<String>>[];
    for (var i = 0; i < dataLines.length && sampleRows.length < 10; i++) {
      final row = _splitLine(dataLines[i], delimiter);
      if (row.length == headers.length) {
        sampleRows.add(row);
      } else if (row.length > 1) {
        // Tolerate minor column count mismatches
        sampleRows.add(row);
      }
    }

    final types = <String>[];
    for (var col = 0; col < headers.length; col++) {
      types.add(_inferType(sampleRows.map((r) => col < r.length ? r[col] : '').toList()));
    }

    final label = delimiter == '\t' ? 'TSV' : 'CSV';
    final buffer = StringBuffer();
    buffer.writeln('[Exploration summary — $label, ~${_fmt(estimatedTokens)} tokens]');
    buffer.writeln('Columns (${headers.length}): ${headers.join(', ')}');
    buffer.writeln('Rows: ${_fmtNum(rowCount)}');
    buffer.writeln('Type inference: ${types.join(', ')}');

    if (sampleRows.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Sample rows:');
      final displayRows = sampleRows.take(3).toList();
      for (var i = 0; i < displayRows.length; i++) {
        buffer.writeln('  ${i + 1}: ${displayRows[i].join(', ')}');
      }
    }

    buffer.writeln();
    buffer.write(
      '[Full content available — ${_fmt(estimatedTokens)} tokens. '
      'Use Read tool to access specific sections]',
    );
    return buffer.toString();
  }

  /// Splits a line on [delimiter], handling basic quoted fields.
  static List<String> _splitLine(String line, String delimiter) {
    if (delimiter == '\t') {
      return line.split('\t').map((s) => s.trim()).toList();
    }

    final fields = <String>[];
    var current = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == delimiter && !inQuotes) {
        fields.add(current.toString().trim());
        current = StringBuffer();
      } else {
        current.write(ch);
      }
    }
    fields.add(current.toString().trim());
    return fields;
  }

  static String _inferType(List<String> values) {
    if (values.isEmpty) return 'string';
    final nonEmpty = values.where((v) => v.isNotEmpty).toList();
    if (nonEmpty.isEmpty) return 'string';

    // Bool
    final boolVals = {'true', 'false', '0', '1', 'yes', 'no'};
    if (nonEmpty.every((v) => boolVals.contains(v.toLowerCase()))) return 'bool';

    // Int
    if (nonEmpty.every((v) => int.tryParse(v) != null)) return 'int';

    // Float
    if (nonEmpty.every((v) => double.tryParse(v) != null)) return 'float';

    // Date (simple ISO pattern)
    final datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}');
    if (nonEmpty.every((v) => datePattern.hasMatch(v))) return 'date';

    return 'string';
  }

  static String _fmt(int n) {
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(1).replaceAll('.0', '')}K';
    }
    return n.toString();
  }

  static String _fmtNum(int n) {
    if (n >= 1000) {
      final s = n.toString();
      final result = StringBuffer();
      for (var i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) result.write(',');
        result.write(s[i]);
      }
      return result.toString();
    }
    return n.toString();
  }
}
