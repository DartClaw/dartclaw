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

  const new({required this.generatedAt, required this.regenerationRecipe, required this.allowlist});

  factory fromJson(Map<String, dynamic> json) {
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

  const new({
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

  const new({
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
        // Only files already past the default are recorded: an entry is a
        // grandfathered exception that may only come down, not a per-file
        // freeze that every ordinary edit trips.
        'F-SIZE-1': {
          for (final entry in fileLoc.entries)
            if (entry.value > workflowFitnessThreshold) entry.key: entry.value,
        },
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
    ..._listDartFiles(p.join(repoRoot, 'packages', 'dartclaw_runtime', 'lib', 'src', 'task')),
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
    final metrics = extractMethodMetrics(relative, sanitized);
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
  final matches = RegExp(r'''['"](_workflow(?:\.[^'"]+)?|_dartclaw\.internal(?:\.[^'"]+)*)['"]''')
      .allMatches(source)
      .map((match) => match.group(1))
      .whereType<String>()
      .toSet();
  return matches;
}

Set<String> _scenarioTypes(String source) {
  final match = RegExp(r'^//\s*scenario-types:\s*(.+)$', multiLine: true).firstMatch(source);
  if (match == null) return const <String>{};
  return match.group(1)!.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty).toSet();
}

final _classDeclaration = RegExp(r'\b(?:abstract\s+|base\s+|sealed\s+|final\s+|interface\s+)*class\s+(\w+)');

/// A `=` that assigns, as opposed to `==`, `!=`, `<=`, `>=` or `=>`.
final _assignment = RegExp(r'(?<![=!<>])=(?![=>])');

/// The members [source] declares, keyed by enclosing class.
///
/// [source] must already be sanitized (see [sanitizeDartSourceForFitness]).
/// Public so the counting rules can be pinned directly - the snapshot is a
/// whole-tree scan and says nothing about which shapes it got right.
List<MethodMetric> extractMethodMetrics(String relativePath, String source) {
  final methods = <MethodMetric>[];
  final lines = const LineSplitter().convert(source);
  final classStack = <({String name, int depth})>[];
  var braceDepth = 0;
  var index = 0;

  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();
    var consumedTo = index;

    final classMatch = _classDeclaration.firstMatch(line);
    if (classMatch != null && line.contains('{')) {
      classStack.add((name: classMatch.group(1)!, depth: braceDepth + _count(line, '{')));
    } else if (_looksLikeMethodStart(trimmed)) {
      final signatureLines = <String>[trimmed];
      var endIndex = index;
      while (!_signatureComplete(signatureLines.join(' ')) && endIndex + 1 < lines.length) {
        endIndex++;
        signatureLines.add(lines[endIndex].trim());
      }
      final signature = signatureLines.join(' ');
      final className = classStack.isEmpty ? null : classStack.last.name;
      final methodName = _declarationName(signature, className);
      if (methodName != null) {
        var body = signature;
        if (!signature.contains('=>') && signature.contains('{')) {
          final bodyLines = <String>[signature];
          var localDepth = _count(signature, '{') - _count(signature, '}');
          while (localDepth > 0 && endIndex + 1 < lines.length) {
            endIndex++;
            bodyLines.add(lines[endIndex]);
            localDepth += _count(lines[endIndex], '{');
            localDepth -= _count(lines[endIndex], '}');
          }
          body = bodyLines.join('\n');
        }
        methods.add(
          MethodMetric(
            filePath: relativePath,
            key: '$relativePath::${className ?? '#top'}::$methodName',
            className: className,
            methodName: methodName,
            complexity: _cyclomaticComplexity(body),
          ),
        );
        consumedTo = endIndex;
      }
    }

    // Every consumed line is accounted for, not just the one the loop is on. A
    // member body whose braces went uncounted left the depth one deeper per
    // member, so an enclosing class never closed and every later top-level
    // declaration was attributed to it.
    for (var i = index; i <= consumedTo; i++) {
      braceDepth += _count(lines[i], '{');
      braceDepth -= _count(lines[i], '}');
    }
    while (classStack.isNotEmpty && braceDepth < classStack.last.depth) {
      classStack.removeLast();
    }
    index = consumedTo + 1;
  }

  return methods;
}

/// Statement heads a token count alone would read as a declaration:
/// `await run.close()` and `case Foo(:final x)` both carry two tokens.
const _statementKeywords = {
  'await',
  'yield',
  'return',
  'throw',
  'assert',
  'case',
  'else',
  'do',
  'try',
  'catch',
  'if',
  'for',
  'while',
  'switch',
  'super',
  'this',
};

/// The member [signature] declares, or null when the line is a statement.
///
/// Two identifiers and a paren do not separate a declaration from a call:
/// `final total = Foo(`, `list.add(x)` and `Future<void> close()` all match
/// that shape, and counting the first two inflates a file's member count with
/// its own field initialisers and formatter-wrapped constructor arguments.
///
/// A declaration head assigns nothing, and either names a type before the
/// member or is the enclosing class's own constructor. This is a heuristic, not
/// a parse - a member declared without a return type reads as a call and is
/// missed. The suite is pinned analyzer-free, so the counts are a trend signal
/// and the frozen per-file baseline is what actually binds.
String? _declarationName(String signature, String? enclosingClass) {
  final getterSetter = RegExp(r'\b(get|set)\s+([A-Za-z_]\w*)').firstMatch(signature);
  if (getterSetter != null) {
    return '${getterSetter.group(1)} ${getterSetter.group(2)}';
  }

  // Each top-level `(` in turn: the first one may belong to a record return
  // type (`({Map? specs}) validateContract(`) rather than to the parameter list.
  for (final open in _topLevelParens(signature)) {
    final name = _declarationNameBefore(signature.substring(0, open).trim(), enclosingClass);
    if (name != null) return name;
  }
  return null;
}

String? _declarationNameBefore(String head, String? enclosingClass) {
  if (head.isEmpty) return null;
  // `operator []=` ends in an `=` that assigns nothing.
  final declaresOperator = head.contains(RegExp(r'\boperator\b'));
  if (!declaresOperator && _assignment.hasMatch(head)) return null;

  // Generics carry the only comma a declaration head may hold; with them gone,
  // a comma or a colon means the line is a map entry or a named argument
  // (`'hunks': hunks.map(`, `status: values.byName(`), whose prefix would
  // otherwise supply the second token a declaration needs.
  final bare = _withoutBracketedRuns(head);
  if (bare.contains(':') || bare.contains(',')) return null;
  // With generics stripped, an operator in the head means the line is an
  // expression, not a declaration: `x ?? Resolver.forPolicy(`, `T v => Foo.of(`.
  if (bare.contains('??')) return null;
  if (!declaresOperator && RegExp(r'[=<>|&+\-*/%~!]').hasMatch(bare)) return null;
  final tokens = bare.split(RegExp(r'\s+')).where((token) => token.isNotEmpty).toList();
  if (tokens.isEmpty || tokens.contains('?') || _statementKeywords.contains(tokens.first)) return null;

  final name = RegExp(r'(operator\s*[^\s(]+|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?)$').firstMatch(head)?.group(0)?.trim();
  if (name == null) return null;
  if (name.startsWith('operator')) return name;

  // `new` is this codebase's primary-constructor name, not a statement.
  final isConstructor =
      enclosingClass != null && (name == 'new' || name == enclosingClass || name.startsWith('$enclosingClass.'));
  if (tokens.length < 2 && !isConstructor) return null;
  return name;
}

/// [source] with every `<...>`, `(...)`, `[...]` and `{...}` run replaced by a
/// single `#`, so a generic or record type is one token rather than the text it
/// encloses - `Map<String, int> toJson` must not read as carrying a comma, and
/// `({int a}) build` must not read as a one-token head.
String _withoutBracketedRuns(String source) {
  const openers = {'<': '>', '(': ')', '[': ']', '{': '}'};
  final out = StringBuffer();
  final stack = <String>[];
  for (final char in source.split('')) {
    if (openers.containsKey(char)) {
      stack.add(openers[char]!);
    } else if (stack.isNotEmpty && stack.last == char) {
      stack.removeLast();
    } else if (stack.isEmpty) {
      out.write(char);
      continue;
    }
    if (stack.length == 1 && openers.containsKey(char)) out.write('#');
  }
  return out.toString();
}

/// The indices of every `(` not already inside a bracket pair, so a closure
/// argument cannot be mistaken for the declaration's parameter list.
///
/// `<`/`>` count as brackets: a generic return type may hold a paren
/// (`Future<(Outcome, String?)> checkBudget(`), and reading that one as the
/// parameter list loses the member.
List<int> _topLevelParens(String signature) {
  final positions = <int>[];
  var depth = 0;
  for (var i = 0; i < signature.length; i++) {
    switch (signature[i]) {
      case '(':
        if (depth == 0) positions.add(i);
        depth++;
      case '[' || '{' || '<':
        depth++;
      case ')' || ']' || '}' || '>':
        if (depth > 0) depth--;
    }
  }
  return positions;
}

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
