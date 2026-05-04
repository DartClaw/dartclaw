import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const workflowFitnessThreshold = 800;
const classMethodThreshold = 25;
const fileMethodThreshold = 40;
const methodComplexityThreshold = 15;
const workflowExecutorDecompositionTrigger = 5500;

const requiredScenarioTypes = <String>{
  'approval',
  'bash',
  'continueSession',
  'foreach',
  'hybrid',
  'loop',
  'map',
  'multi-prompt',
  'parallel',
  'plain',
};

final class FitnessBaseline {
  final String generatedAt;
  final String regenerationRecipe;
  final Map<String, Map<String, Object?>> allowlist;

  const FitnessBaseline({required this.generatedAt, required this.regenerationRecipe, required this.allowlist});

  factory FitnessBaseline.fromJson(Map<String, dynamic> json) {
    final rawAllowlist = (json['allowlist'] as Map<String, dynamic>? ?? const <String, dynamic>{});
    return FitnessBaseline(
      generatedAt: json['generated_at'] as String? ?? '',
      regenerationRecipe: json['regeneration_recipe'] as String? ?? '',
      allowlist: {
        for (final entry in rawAllowlist.entries)
          entry.key: (entry.value as Map<String, dynamic>? ?? const <String, dynamic>{}).map(
            (key, value) => MapEntry(key, value),
          ),
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'generated_at': generatedAt,
    'regeneration_recipe': regenerationRecipe,
    'allowlist': {for (final entry in allowlist.entries) entry.key: entry.value},
  };
}

final class MethodMetric {
  final String filePath;
  final String key;
  final String? className;
  final String methodName;
  final int complexity;

  const MethodMetric({
    required this.filePath,
    required this.key,
    required this.className,
    required this.methodName,
    required this.complexity,
  });
}

final class FitnessSnapshot {
  final Map<String, int> fileLoc;
  final Map<String, int> classMethodCounts;
  final Map<String, int> fileMethodCounts;
  final Map<String, int> methodComplexities;
  final Map<String, Set<String>> contractKeysByFile;
  final Set<String> scenarioTypes;
  final List<String> scenarioFiles;

  const FitnessSnapshot({
    required this.fileLoc,
    required this.classMethodCounts,
    required this.fileMethodCounts,
    required this.methodComplexities,
    required this.contractKeysByFile,
    required this.scenarioTypes,
    required this.scenarioFiles,
  });

  FitnessBaseline toBaseline({required String generatedAt}) {
    return FitnessBaseline(
      generatedAt: generatedAt,
      regenerationRecipe: 'dart run packages/dartclaw_workflow/tool/regenerate_fitness_baseline.dart',
      allowlist: {
        'F-SIZE-1': {for (final entry in fileLoc.entries) entry.key: entry.value},
        'F-CLASS-1': {for (final entry in classMethodCounts.entries) entry.key: entry.value},
        'F-CLASS-2': {for (final entry in fileMethodCounts.entries) entry.key: entry.value},
        'F-COMPLEX-1': {for (final entry in methodComplexities.entries) entry.key: entry.value},
        'F-CONTRACT-1': {
          for (final entry in contractKeysByFile.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value.toList()..sort(),
        },
      },
    );
  }
}

String resolveRepoRoot() {
  var current = Directory.current.absolute;
  while (true) {
    final candidate = Directory(p.join(current.path, 'packages', 'dartclaw_workflow'));
    if (candidate.existsSync()) {
      return current.path;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not resolve the DartClaw workspace root.');
    }
    current = parent;
  }
}

String baselinePath(String repoRoot) =>
    p.join(repoRoot, 'packages', 'dartclaw_workflow', 'test', 'fitness_baseline.json');

FitnessBaseline loadBaseline(String repoRoot) {
  final file = File(baselinePath(repoRoot));
  return FitnessBaseline.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
}

String sanitizeDartSourceForFitness(String source) => _sanitizeDartSource(source);

String? sizeViolationMessage(String filePath, int currentLoc, int ceiling) {
  if (currentLoc <= ceiling) return null;
  return 'File $filePath grew to $currentLoc LOC; allow-list ceiling is $ceiling.';
}

FitnessSnapshot collectFitnessSnapshot(String repoRoot) {
  final files = [
    ..._listDartFiles(p.join(repoRoot, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow')),
    ..._listDartFiles(p.join(repoRoot, 'packages', 'dartclaw_server', 'lib', 'src', 'task')),
  ]..sort((a, b) => a.path.compareTo(b.path));

  final fileLoc = <String, int>{};
  final classMethodCounts = <String, int>{};
  final fileMethodCounts = <String, int>{};
  final methodComplexities = <String, int>{};
  final contractKeysByFile = <String, Set<String>>{};

  for (final file in files) {
    final relative = p.relative(file.path, from: repoRoot);
    final source = file.readAsStringSync();
    final sanitized = _sanitizeDartSource(source);

    fileLoc[relative] = file.readAsLinesSync().length;
    final metrics = _extractMethodMetrics(relative, sanitized);
    fileMethodCounts[relative] = metrics.length;
    for (final metric in metrics) {
      methodComplexities[metric.key] = metric.complexity;
      if (metric.className case final className?) {
        final classKey = '$relative::$className';
        classMethodCounts[classKey] = (classMethodCounts[classKey] ?? 0) + 1;
      }
    }
    contractKeysByFile[relative] = _contractKeys(source);
  }

  final scenarioFiles = _listDartFiles(
    p.join(repoRoot, 'packages', 'dartclaw_workflow', 'test', 'workflow', 'scenarios'),
  ).map((file) => p.relative(file.path, from: repoRoot)).where((file) => file.endsWith('_test.dart')).toList()..sort();
  final scenarioTypes = <String>{};
  for (final relative in scenarioFiles) {
    final source = File(p.join(repoRoot, relative)).readAsStringSync();
    scenarioTypes.addAll(_scenarioTypes(source));
  }

  return FitnessSnapshot(
    fileLoc: fileLoc,
    classMethodCounts: classMethodCounts,
    fileMethodCounts: fileMethodCounts,
    methodComplexities: methodComplexities,
    contractKeysByFile: contractKeysByFile,
    scenarioTypes: scenarioTypes,
    scenarioFiles: scenarioFiles,
  );
}

List<File> _listDartFiles(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const <File>[];
  return dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList(growable: false);
}

Set<String> _contractKeys(String source) {
  final matches = RegExp(
    r'''['"](_workflow(?:\.[^'"]+)?|_dartclaw\.internal(?:\.[^'"]+)*)['"]''',
  ).allMatches(source).map((match) => match.group(1)).whereType<String>().toSet();
  return matches;
}

Set<String> _scenarioTypes(String source) {
  final match = RegExp(r'^//\s*scenario-types:\s*(.+)$', multiLine: true).firstMatch(source);
  if (match == null) return const <String>{};
  return match.group(1)!.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty).toSet();
}

List<MethodMetric> _extractMethodMetrics(String relativePath, String source) {
  final methods = <MethodMetric>[];
  final lines = const LineSplitter().convert(source);
  final classStack = <({String name, int depth})>[];
  var braceDepth = 0;
  var index = 0;

  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();

    final classMatch = RegExp(
      r'\b(?:abstract\s+|base\s+|sealed\s+|final\s+|interface\s+)*class\s+(\w+)',
    ).firstMatch(line);
    if (classMatch != null && line.contains('{')) {
      classStack.add((name: classMatch.group(1)!, depth: braceDepth + _count(line, '{')));
    }

    if (_looksLikeMethodStart(trimmed)) {
      final signatureLines = <String>[trimmed];
      var endIndex = index;
      while (!_signatureComplete(signatureLines.join(' ')) && endIndex + 1 < lines.length) {
        endIndex++;
        signatureLines.add(lines[endIndex].trim());
      }
      final signature = signatureLines.join(' ');
      final methodName = _methodName(signature);
      if (methodName != null && !_isControlKeyword(methodName)) {
        final className = classStack.isEmpty ? null : classStack.last.name;
        if (signature.contains('=>')) {
          methods.add(
            MethodMetric(
              filePath: relativePath,
              key: '$relativePath::${className ?? '#top'}::$methodName',
              className: className,
              methodName: methodName,
              complexity: _cyclomaticComplexity(signature),
            ),
          );
          index = endIndex;
        } else if (signature.contains('{')) {
          final bodyLines = <String>[signature];
          var localDepth = _count(signature, '{') - _count(signature, '}');
          while (localDepth > 0 && endIndex + 1 < lines.length) {
            endIndex++;
            final bodyLine = lines[endIndex];
            bodyLines.add(bodyLine);
            localDepth += _count(bodyLine, '{');
            localDepth -= _count(bodyLine, '}');
          }
          methods.add(
            MethodMetric(
              filePath: relativePath,
              key: '$relativePath::${className ?? '#top'}::$methodName',
              className: className,
              methodName: methodName,
              complexity: _cyclomaticComplexity(bodyLines.join('\n')),
            ),
          );
          index = endIndex;
        }
      }
    }

    braceDepth += _count(line, '{');
    braceDepth -= _count(line, '}');
    while (classStack.isNotEmpty && braceDepth < classStack.last.depth) {
      classStack.removeLast();
    }
    index++;
  }

  return methods;
}

bool _isControlKeyword(String rawName) => switch (rawName.trim()) {
  'if' || 'for' || 'while' || 'switch' || 'catch' || 'return' || 'throw' || 'assert' => true,
  _ => false,
};

int _cyclomaticComplexity(String body) {
  var complexity = 1;
  complexity += RegExp(r'\bif\b').allMatches(body).length;
  complexity += RegExp(r'\bfor\b').allMatches(body).length;
  complexity += RegExp(r'\bwhile\b').allMatches(body).length;
  complexity += RegExp(r'\bcase\b').allMatches(body).length;
  complexity += RegExp(r'\bcatch\b').allMatches(body).length;
  complexity += RegExp(r'&&').allMatches(body).length;
  complexity += RegExp(r'\|\|').allMatches(body).length;
  complexity += RegExp(r'\?').allMatches(body).length;
  return complexity;
}

bool _looksLikeMethodStart(String trimmed) {
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('//')) return false;
  if (!trimmed.contains('(') &&
      !trimmed.contains(' get ') &&
      !trimmed.startsWith('get ') &&
      !trimmed.contains(' set ')) {
    return false;
  }
  final disallowed = ['if ', 'for ', 'while ', 'switch ', 'catch ', 'return ', 'throw ', 'assert('];
  return disallowed.every((prefix) => !trimmed.startsWith(prefix));
}

bool _signatureComplete(String signature) =>
    signature.contains('=>') || signature.contains('{') || signature.endsWith(';');

String? _methodName(String signature) {
  final getterSetter = RegExp(r'\b(get|set)\s+([A-Za-z_]\w*)').firstMatch(signature);
  if (getterSetter != null) {
    return '${getterSetter.group(1)} ${getterSetter.group(2)}';
  }
  RegExpMatch? regular;
  for (final match in RegExp(r'([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?|operator\s+[^\s(]+)\s*\(').allMatches(signature)) {
    regular = match;
  }
  return regular?.group(1)?.trim();
}

int _count(String source, String char) => RegExp(RegExp.escape(char)).allMatches(source).length;

String _sanitizeDartSource(String source) {
  final buffer = StringBuffer();
  var i = 0;
  var inLineComment = false;
  var inBlockComment = false;
  String? stringDelimiter;
  var tripleQuoted = false;
  var escaping = false;

  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    final next2 = i + 2 < source.length ? source[i + 2] : '';

    if (inLineComment) {
      if (char == '\n') {
        inLineComment = false;
        buffer.write('\n');
      } else {
        buffer.write(' ');
      }
      i++;
      continue;
    }

    if (inBlockComment) {
      if (char == '*' && next == '/') {
        buffer.write('  ');
        inBlockComment = false;
        i += 2;
      } else {
        buffer.write(char == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }

    if (stringDelimiter != null) {
      if (escaping) {
        escaping = false;
        buffer.write(char == '\n' ? '\n' : ' ');
        i++;
        continue;
      }
      if (char == r'\') {
        escaping = true;
        buffer.write(' ');
        i++;
        continue;
      }
      final isTripleClose =
          tripleQuoted && char == stringDelimiter && next == stringDelimiter && next2 == stringDelimiter;
      if (isTripleClose) {
        buffer.write('   ');
        stringDelimiter = null;
        tripleQuoted = false;
        i += 3;
        continue;
      }
      if (!tripleQuoted && char == stringDelimiter) {
        buffer.write(' ');
        stringDelimiter = null;
        i++;
        continue;
      }
      buffer.write(char == '\n' ? '\n' : ' ');
      i++;
      continue;
    }

    if (char == '/' && next == '/') {
      buffer.write('  ');
      inLineComment = true;
      i += 2;
      continue;
    }
    if (char == '/' && next == '*') {
      buffer.write('  ');
      inBlockComment = true;
      i += 2;
      continue;
    }
    if ((char == "'" || char == '"') && next == char && next2 == char) {
      buffer.write('   ');
      stringDelimiter = char;
      tripleQuoted = true;
      i += 3;
      continue;
    }
    if (char == "'" || char == '"') {
      buffer.write(' ');
      stringDelimiter = char;
      tripleQuoted = false;
      i++;
      continue;
    }
    buffer.write(char);
    i++;
  }

  return buffer.toString();
}
