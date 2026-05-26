// Fitness function: no public constructor may have more than 12 parameters.
//
// What this enforces:
//   Every public class constructor in packages/<X>/lib/**/*.dart and
//   apps/<X>/lib/**/*.dart must have ≤ 12 parameters (named + positional
//   combined). Known violators are listed in `allowlist/constructor_param_count.txt`
//   with a remediation story.
//
// Why:
//   Constructors with >12 parameters are a reliable signal of a missing
//   parameter object or dependency-group struct. They are hard to call,
//   hard to test, and accumulate as a tax on every consumer. The ceiling
//   forces the conversation about grouping at design time.
//
// How to resolve a failure:
//   Option A (preferred): Introduce a parameter-object struct to group related
//   parameters (e.g. _ServerCoreDeps, _ServerTurnDeps) so each constructor
//   stays ≤ 12 arguments.
//   Option B (intentional exception): Add an entry to
//   `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt`
//   with format `<ClassName>.<ctorName>  # <param-count>; <remediation>`.
//   The rationale and remediation story are mandatory.

import 'dart:io';

import 'package:test/test.dart';

const _paramLimit = 12;

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'constructor_param_count.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File(
      '$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt',
    );
    _assertAllowlistFormat(allowlistFile);
  });

  test('no public constructor exceeds $_paramLimit parameters', () {
    final violations = <String>[];

    for (final file in _findDartFiles(repoRoot)) {
      final relativePath = _relativeTo(file.path, repoRoot);
      final source = file.readAsStringSync();
      _checkCtors(source, relativePath, allowlist, violations);
    }

    if (violations.isNotEmpty) {
      fail(
        'Constructor parameter count violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}

void _checkCtors(String source, String relativePath, Map<String, String> allowlist, List<String> violations) {
  // Find class declarations to extract the class name.
  final classPattern = RegExp(
    r'(?:^|\n)\s*(?:abstract\s+|final\s+|sealed\s+|interface\s+|mixin\s+|base\s+)*class\s+(\w+)',
  );

  for (final classMatch in classPattern.allMatches(source)) {
    final className = classMatch.group(1)!;
    // Only check public classes (no leading underscore).
    if (className.startsWith('_')) continue;

    // Look for constructors of this class starting after the class declaration.
    final afterClass = source.substring(classMatch.start);

    // Match: ClassName(, ClassName.named(, const ClassName(, factory ClassName(, etc.
    final ctorPattern = RegExp(
      r'(?:^|\n)\s*(?:const\s+|factory\s+)?'
      '${RegExp.escape(className)}'
      r'(\.\w+)?\s*\(',
    );

    for (final ctorMatch in ctorPattern.allMatches(afterClass)) {
      final ctorNameSuffix = ctorMatch.group(1) ?? '';
      final ctorKey = ctorNameSuffix.isNotEmpty ? '$className${ctorNameSuffix.substring(1)}' : className;

      // Skip private constructors (underscore after dot).
      // Private: ClassName._something or allowlisted as ClassName._
      final isPrivateCtor = ctorNameSuffix.startsWith('._');

      // Allowlist key format: "ClassName._" for private ctor, "ClassName.named" for named, "ClassName" for default.
      final allowlistKey = isPrivateCtor ? '$className.${ctorNameSuffix.substring(1)}' : ctorKey;

      // Find the opening paren and count params.
      final parenStart = ctorMatch.start + ctorMatch.group(0)!.length - 1;
      final paramCount = _countParams(afterClass, parenStart);
      if (paramCount == null) continue;

      if (paramCount > _paramLimit) {
        if (!allowlist.containsKey(allowlistKey)) {
          violations.add(
            '$relativePath: $ctorKey has $paramCount parameters (limit $_paramLimit) — '
            'introduce parameter objects or add to allowlist/constructor_param_count.txt',
          );
        }
      }
    }
  }
}

/// Counts top-level comma-separated entries between the `(` at [start] and its
/// matching `)`. Returns null if parsing fails (e.g. file is incomplete).
int? _countParams(String source, int start) {
  if (start >= source.length || source[start] != '(') return null;

  var depth = 0;
  var commaCount = 0;
  var hasContent = false;
  var inString = false;
  var stringChar = '';

  for (var i = start; i < source.length; i++) {
    final ch = source[i];

    if (inString) {
      if (ch == stringChar && (i == 0 || source[i - 1] != '\\')) {
        inString = false;
      }
      continue;
    }

    if (ch == "'" || ch == '"') {
      inString = true;
      stringChar = ch;
      continue;
    }

    if (ch == '(') {
      depth++;
      if (depth == 1) continue;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) {
        return hasContent ? commaCount + 1 : 0;
      }
    } else if (ch == '{' || ch == '[' || ch == '<') {
      depth++;
    } else if (ch == '}' || ch == ']' || ch == '>') {
      depth--;
    } else if (ch == ',' && depth == 1) {
      commaCount++;
      hasContent = true;
    } else if (depth == 1 && ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t') {
      hasContent = true;
    }
  }
  return null;
}

Iterable<File> _findDartFiles(String repoRoot) sync* {
  for (final baseDir in ['packages', 'apps']) {
    final dir = Directory('$repoRoot/$baseDir');
    if (!dir.existsSync()) continue;
    for (final pkg in dir.listSync().whereType<Directory>()) {
      final libDir = Directory('${pkg.path}/lib');
      if (!libDir.existsSync()) continue;
      for (final entity in libDir.listSync(recursive: true).whereType<File>()) {
        if (entity.path.endsWith('.dart')) yield entity;
      }
    }
  }
}

String _findRepoRoot() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

Map<String, String> _readAllowlist(String repoRoot, String filename) {
  final file = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/$filename');
  if (!file.existsSync()) return {};
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) continue;
    result[stripped.substring(0, sep)] = stripped.substring(sep + 4);
  }
  return result;
}

void _assertAllowlistFormat(File allowlistFile) {
  if (!allowlistFile.existsSync()) return;
  final bad = <String>[];
  final lines = allowlistFile.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final stripped = lines[i].trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) {
      bad.add('line ${i + 1}: missing "  # " separator');
      continue;
    }
    if (stripped.substring(sep + 4).trim().isEmpty) {
      bad.add('line ${i + 1}: rationale is empty');
    }
  }
  if (bad.isNotEmpty) {
    fail(
      'Malformed allowlist ${allowlistFile.path}:\n'
      '  ${bad.join('\n  ')}\n'
      'Each non-comment line must be: <ClassName>.<ctorName>  # <non-empty rationale>',
    );
  }
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
