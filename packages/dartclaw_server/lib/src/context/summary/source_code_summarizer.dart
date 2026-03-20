import '../type_detector.dart';

/// Extracts top-level declarations from source code using regex patterns.
abstract final class SourceCodeSummarizer {
  /// Returns a formatted declaration listing or null if no declarations found.
  static String? summarize(String content, ContentType type, int estimatedTokens) {
    try {
      return _summarize(content, type, estimatedTokens);
    } catch (_) {
      return null;
    }
  }

  static String? _summarize(String content, ContentType type, int estimatedTokens) {
    final (label, declarations, imports) = switch (type) {
      ContentType.dart => _parseDart(content),
      ContentType.typescript => _parseTypeScript(content),
      ContentType.python => _parsePython(content),
      ContentType.go => _parseGo(content),
      _ => ('Unknown', <String, List<String>>{}, 0),
    };

    if (declarations.isEmpty || declarations.values.every((v) => v.isEmpty)) {
      return null;
    }

    final buffer = StringBuffer();
    buffer.writeln('[Exploration summary — $label source, ~${_fmt(estimatedTokens)} tokens]');

    final totalDeclarations = declarations.values.fold(0, (sum, v) => sum + v.length);
    buffer.writeln('Declarations ($totalDeclarations):');

    for (final entry in declarations.entries) {
      if (entry.value.isEmpty) continue;
      buffer.writeln('  ${entry.key} (${entry.value.length}): ${entry.value.join(', ')}');
    }

    if (imports > 0) {
      buffer.writeln();
      buffer.writeln('Imports ($imports)');
    }

    buffer.writeln();
    buffer.write(
      '[Full content available — ${_fmt(estimatedTokens)} tokens. '
      'Use Read tool to access specific sections]',
    );
    return buffer.toString();
  }

  static (String, Map<String, List<String>>, int) _parseDart(String content) {
    final classes = <String>[];
    final mixins = <String>[];
    final enums = <String>[];
    final extensions = <String>[];
    final typedefs = <String>[];
    final functions = <String>[];
    var imports = 0;

    final lines = content.split('\n');
    for (final line in lines) {
      final t = line.trimLeft();

      // Imports
      if (t.startsWith('import ') || t.startsWith('export ') || t.startsWith('part ')) {
        imports++;
        continue;
      }

      // Classes (abstract, base, final, sealed, etc.)
      final classMatch = RegExp(r'^(?:(?:abstract|base|final|sealed|interface)\s+)*class\s+(\w+)').firstMatch(t);
      if (classMatch != null) {
        classes.add(classMatch.group(1)!);
        continue;
      }

      // Mixins
      final mixinMatch = RegExp(r'^(?:base\s+)?mixin\s+(\w+)').firstMatch(t);
      if (mixinMatch != null) {
        mixins.add(mixinMatch.group(1)!);
        continue;
      }

      // Enums
      final enumMatch = RegExp(r'^enum\s+(\w+)').firstMatch(t);
      if (enumMatch != null) {
        enums.add(enumMatch.group(1)!);
        continue;
      }

      // Extensions
      final extMatch = RegExp(r'^extension\s+(\w*)').firstMatch(t);
      if (extMatch != null) {
        final name = extMatch.group(1);
        extensions.add(name != null && name.isNotEmpty ? name : '(unnamed)');
        continue;
      }

      // Typedefs
      final typedefMatch = RegExp(r'^typedef\s+(\w+)').firstMatch(t);
      if (typedefMatch != null) {
        typedefs.add(typedefMatch.group(1)!);
        continue;
      }

      // Top-level functions: identifier followed by ( not inside a class body
      // Heuristic: non-indented line with word chars followed by (
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        final fnMatch = RegExp(r'^(?:[\w<>\?]+\s+)+(\w+)\s*\(').firstMatch(t);
        if (fnMatch != null && !_isDartKeyword(fnMatch.group(1)!)) {
          functions.add(fnMatch.group(1)!);
        }
      }
    }

    return (
      'Dart',
      {
        'Classes': classes,
        'Mixins': mixins,
        'Enums': enums,
        'Extensions': extensions,
        'Typedefs': typedefs,
        'Functions': functions,
      },
      imports,
    );
  }

  static (String, Map<String, List<String>>, int) _parseTypeScript(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final interfaces = <String>[];
    final types = <String>[];
    final enums = <String>[];
    var imports = 0;

    final lines = content.split('\n');
    for (final line in lines) {
      final t = line.trimLeft();

      if (t.startsWith('import ') || t.startsWith('export {') || t.startsWith("import '") || t.startsWith('import "')) {
        imports++;
        continue;
      }

      // export default class / class
      final classMatch = RegExp(r'^(?:export\s+(?:default\s+)?)?class\s+(\w+)').firstMatch(t);
      if (classMatch != null) {
        classes.add(classMatch.group(1)!);
        continue;
      }

      // export function / function
      final fnMatch = RegExp(r'^(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s+(\w+)').firstMatch(t);
      if (fnMatch != null) {
        functions.add(fnMatch.group(1)!);
        continue;
      }

      // Arrow function: export const name = (...) =>
      final arrowMatch = RegExp(r'^(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?\(').firstMatch(t);
      if (arrowMatch != null) {
        functions.add(arrowMatch.group(1)!);
        continue;
      }

      // interface
      final ifaceMatch = RegExp(r'^(?:export\s+)?interface\s+(\w+)').firstMatch(t);
      if (ifaceMatch != null) {
        interfaces.add(ifaceMatch.group(1)!);
        continue;
      }

      // type alias
      final typeMatch = RegExp(r'^(?:export\s+)?type\s+(\w+)\s*=').firstMatch(t);
      if (typeMatch != null) {
        types.add(typeMatch.group(1)!);
        continue;
      }

      // enum
      final enumMatch = RegExp(r'^(?:export\s+)?(?:const\s+)?enum\s+(\w+)').firstMatch(t);
      if (enumMatch != null) {
        enums.add(enumMatch.group(1)!);
      }
    }

    return (
      'TypeScript',
      {'Classes': classes, 'Functions': functions, 'Interfaces': interfaces, 'Types': types, 'Enums': enums},
      imports,
    );
  }

  static (String, Map<String, List<String>>, int) _parsePython(String content) {
    final classes = <String>[];
    final functions = <String>[];
    final assignments = <String>[];
    var imports = 0;

    final lines = content.split('\n');
    for (final line in lines) {
      final t = line.trimLeft();

      if (t.startsWith('import ') || t.startsWith('from ')) {
        imports++;
        continue;
      }

      // Top-level declarations (no indent)
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        final classMatch = RegExp(r'^class\s+(\w+)').firstMatch(t);
        if (classMatch != null) {
          classes.add(classMatch.group(1)!);
          continue;
        }

        final fnMatch = RegExp(r'^(?:async\s+)?def\s+(\w+)').firstMatch(t);
        if (fnMatch != null) {
          functions.add(fnMatch.group(1)!);
          continue;
        }

        // Top-level assignments: NAME = ... (UPPER_CASE constants and regular variables)
        final assignMatch = RegExp(r'^([A-Za-z_]\w*)\s*[=:]').firstMatch(t);
        if (assignMatch != null) {
          final name = assignMatch.group(1)!;
          // Skip Python keywords and common non-assignment patterns
          if (!_isPythonKeyword(name)) {
            assignments.add(name);
          }
        }
      }
    }

    return ('Python', {'Classes': classes, 'Functions': functions, 'Assignments': assignments}, imports);
  }

  static bool _isPythonKeyword(String word) {
    const keywords = {
      'if',
      'else',
      'elif',
      'for',
      'while',
      'with',
      'try',
      'except',
      'finally',
      'raise',
      'return',
      'yield',
      'break',
      'continue',
      'pass',
      'assert',
      'del',
      'global',
      'nonlocal',
      'lambda',
      'not',
      'and',
      'or',
      'is',
      'in',
      'True',
      'False',
      'None',
    };
    return keywords.contains(word);
  }

  static (String, Map<String, List<String>>, int) _parseGo(String content) {
    final structs = <String>[];
    final interfaces = <String>[];
    final functions = <String>[];
    var imports = 0;

    final lines = content.split('\n');
    for (final line in lines) {
      final t = line.trimLeft();

      if (t.startsWith('import ') || t.startsWith('import (')) {
        imports++;
        continue;
      }

      // type X struct / type X interface
      final typeMatch = RegExp(r'^type\s+(\w+)\s+(struct|interface)').firstMatch(t);
      if (typeMatch != null) {
        if (typeMatch.group(2) == 'struct') {
          structs.add(typeMatch.group(1)!);
        } else {
          interfaces.add(typeMatch.group(1)!);
        }
        continue;
      }

      // func (receiver) Name(...) or func Name(...)
      final fnMatch = RegExp(r'^func\s+(?:\([^)]*\)\s+)?(\w+)\s*\(').firstMatch(t);
      if (fnMatch != null) {
        functions.add(fnMatch.group(1)!);
      }
    }

    return ('Go', {'Structs': structs, 'Interfaces': interfaces, 'Functions': functions}, imports);
  }

  static bool _isDartKeyword(String word) {
    const keywords = {
      'if',
      'else',
      'for',
      'while',
      'do',
      'switch',
      'case',
      'return',
      'try',
      'catch',
      'finally',
      'throw',
      'new',
      'await',
      'async',
      'yield',
      'in',
      'is',
      'as',
      'var',
      'final',
      'const',
      'late',
      'required',
      'external',
      'factory',
      'static',
      'get',
      'set',
    };
    return keywords.contains(word);
  }

  static String _fmt(int n) {
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(1).replaceAll('.0', '')}K';
    }
    return n.toString();
  }
}
