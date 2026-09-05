import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Repo-root-relative home of this suite - the one place it is written down.
const fitnessSuiteDir = 'dev/fitness';

/// Repo-root-relative path of the suite README that gate failures point at.
const fitnessReadmePath = '$fitnessSuiteDir/README.md';

File allowlistFile(String repoRoot, String filename) => File('$repoRoot/$fitnessSuiteDir/test/allowlist/$filename');

/// Repo-root-relative path of the declared package tier order.
const packageTiersPath = 'dev/package_tiers.txt';

/// The class-modifier prefix a Dart declaration may carry, as a regex fragment.
///
/// One authority for three gates that each scan declarations for a different
/// question — [no_duplicate_local_fakes_test.dart], [constructor_param_count_test.dart]
/// and [no_second_implementation_test.dart]. They differ deliberately in what
/// they anchor on and which kinds they read; they must not differ in which
/// modifiers they recognise, which is how two of them had already drifted.
const dartDeclarationModifiers = r'(?:abstract\s+|base\s+|final\s+|interface\s+|mixin\s+|sealed\s+)*';

/// A member of the root pubspec's `workspace:` list.
class WorkspaceMember {
  const new(this.name, this.path);

  final String name;

  /// Absolute path of the member directory.
  final String path;
}

bool isDartclawPackage(String name) => name == 'dartclaw' || name.startsWith('dartclaw_');

/// The workspace members, read from the root pubspec — the one place the set is
/// declared, so a member added there cannot escape a gate that enumerates them.
List<WorkspaceMember> workspaceMembers(String repoRoot) {
  final lines = File('$repoRoot/pubspec.yaml').readAsLinesSync();
  final members = <WorkspaceMember>[];
  var inBlock = false;
  for (final line in lines) {
    if (!line.startsWith(' ') && line.trim() == 'workspace:') {
      inBlock = true;
      continue;
    }
    if (!inBlock) continue;
    if (line.isNotEmpty && !line.startsWith(' ')) break;
    final match = RegExp(r'^\s+-\s+(\S+)\s*$').firstMatch(line);
    if (match == null) continue;
    final relative = match.group(1)!;
    members.add(WorkspaceMember(_memberName('$repoRoot/$relative'), '$repoRoot/$relative'));
  }
  if (members.isEmpty) {
    fail('No workspace members found in $repoRoot/pubspec.yaml');
  }
  return members;
}

List<String> workspaceMemberNames(String repoRoot) => [for (final member in workspaceMembers(repoRoot)) member.name];

String _memberName(String memberPath) {
  final pubspec = File('$memberPath/pubspec.yaml');
  if (!pubspec.existsSync()) fail('Workspace member $memberPath has no pubspec.yaml');
  for (final line in pubspec.readAsLinesSync()) {
    final match = RegExp(r'^name:\s*(\S+)').firstMatch(line);
    if (match != null) return match.group(1)!;
  }
  fail('Workspace member $memberPath declares no package name');
}

/// The declared tier order: package name to tier position, higher depends on lower.
Map<String, int> readPackageTiers(String repoRoot) {
  final file = File('$repoRoot/$packageTiersPath');
  if (!file.existsSync()) fail('Missing $packageTiersPath');
  final tiers = <String, int>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final match = RegExp(r'^T(\d+):\s*(.*)$').firstMatch(stripped);
    if (match == null) fail('Malformed line in $packageTiersPath: $stripped');
    final tier = int.parse(match.group(1)!);
    for (final name in match.group(2)!.split(RegExp(r'\s+')).where((part) => part.isNotEmpty)) {
      if (tiers.containsKey(name)) fail('$packageTiersPath assigns $name more than one tier');
      tiers[name] = tier;
    }
  }
  return tiers;
}

/// DartClaw package names under a member's `dependencies:` block. `dev_dependencies`
/// are deliberately excluded: a test-only edge is not a shipped dependency.
Set<String> declaredDartclawDependencies(String memberPath) {
  final pubspec = File('$memberPath/pubspec.yaml');
  if (!pubspec.existsSync()) return const {};
  return topLevelKeysInBlock(pubspec.readAsLinesSync(), 'dependencies:').where(isDartclawPackage).toSet();
}

String findRepoRoot() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

/// An allowlist that records which keys its gate actually consulted.
///
/// An entry stops guarding *silently* once its subject disappears — a renamed
/// path, a shifted `path:line`, an edge that no longer exists. Recording the
/// lookups lets a gate assert at teardown that every entry was reached, so a
/// stale entry fails instead of quietly permitting nothing.
///
/// A gate that reads whole-list views (`keys`, `entries`, `forEach`) consults
/// every entry by construction, so those mark the whole list. A gate that only
/// *reports* on the whole list without deciding anything from it reads
/// [rawKeys], which marks nothing — otherwise that read alone would make the
/// staleness assertion vacuous.
class Allowlist {
  new(this.file, this._entries);

  /// The allowlist file, named in the staleness failure so the fix is obvious.
  final File file;

  final Map<String, String> _entries;
  final Set<String> _consulted = {};

  bool containsKey(String key) {
    _consulted.add(key);
    return _entries.containsKey(key);
  }

  String? operator [](String key) {
    _consulted.add(key);
    return _entries[key];
  }

  Iterable<String> get keys => _consultAll().keys;

  /// The keys without recording a lookup, for a gate that scans the whole list
  /// to *report* on it rather than to decide a violation from it.
  Iterable<String> get rawKeys => _entries.keys;

  Iterable<MapEntry<String, String>> get entries => _consultAll().entries;

  void forEach(void Function(String key, String rationale) action) => _consultAll().forEach(action);

  bool get isEmpty => _entries.isEmpty;

  bool get isNotEmpty => _entries.isNotEmpty;

  int get length => _entries.length;

  /// Fails when an entry was never looked up during the run, which means the
  /// thing it allowlisted no longer exists.
  void assertNoStaleEntries() {
    final stale = _entries.keys.where((key) => !_consulted.contains(key)).toList()..sort();
    if (stale.isEmpty) return;
    fail(
      'Stale allowlist entries in ${relativeTo(file.path, findRepoRoot())}:\n'
      '  ${stale.join('\n  ')}\n'
      'Each names something the gate never saw — a moved or deleted path, a shifted position, '
      'or an edge that is gone. Remove the entry or re-key it.',
    );
  }

  Map<String, String> _consultAll() {
    _consulted.addAll(_entries.keys);
    return _entries;
  }
}

Allowlist readAllowlist(String repoRoot, String filename) {
  final file = allowlistFile(repoRoot, filename);
  if (!file.existsSync()) return Allowlist(file, const {});
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) continue;
    // Trimmed: `assertAllowlistFormat` accepts a wider separator than this
    // split, so a three-space entry would otherwise yield a key with a baked-in
    // trailing space that can never match — and would then read as stale.
    result[stripped.substring(0, sep).trim()] = stripped.substring(sep + 4).trim();
  }
  return Allowlist(file, result);
}

void assertAllowlistFormat(File allowlistFile, {String entryFormat = '<pattern>'}) {
  if (!allowlistFile.existsSync()) return;
  final bad = <String>[];
  final lines = allowlistFile.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final stripped = lines[i].trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  #');
    if (sep < 0) {
      bad.add('line ${i + 1}: missing "  # " separator');
      continue;
    }
    final rationale = stripped.substring(sep + 3);
    if (rationale.trim().isEmpty) {
      bad.add('line ${i + 1}: rationale is empty');
    } else if (!rationale.startsWith(' ')) {
      bad.add('line ${i + 1}: missing "  # " separator');
    }
  }
  if (bad.isNotEmpty) {
    fail(
      'Malformed allowlist ${allowlistFile.path}:\n'
      '  ${bad.join('\n  ')}\n'
      'Each non-comment line must be: $entryFormat  # <non-empty rationale>',
    );
  }
}

/// Every `.dart` file under the test trees, suite helpers included. A helper
/// that declares a fake is as much a declaration site as a `_test.dart` file,
/// so a gate about declarations reads this rather than [testDartFiles].
Iterable<File> testTreeDartFiles(String repoRoot) sync* {
  for (final rootName in const ['packages', 'apps', '$fitnessSuiteDir/test']) {
    final root = Directory('$repoRoot/$rootName');
    if (!root.existsSync()) continue;
    for (final file in root.listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart')) continue;
      if (rootName != '$fitnessSuiteDir/test' && !path.contains('/test/')) continue;
      yield file;
    }
  }
}

/// The `*_test.dart` subset of [testTreeDartFiles] — suites, not their helpers.
///
/// It inherits that walk's reach, so a `*_test.dart` file outside a `/test/`
/// directory is not returned. None exists today.
Iterable<File> testDartFiles(String repoRoot) =>
    testTreeDartFiles(repoRoot).where((file) => file.path.endsWith('_test.dart'));

Iterable<File> productionDartFiles(String repoRoot, {bool srcOnly = false}) sync* {
  for (final rootName in const ['packages', 'apps']) {
    final root = Directory('$repoRoot/$rootName');
    if (!root.existsSync()) continue;
    for (final member in root.listSync().whereType<Directory>()) {
      final lib = Directory('${member.path}/lib${srcOnly ? '/src' : ''}');
      if (!lib.existsSync()) continue;
      yield* lib.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'));
    }
  }
}

String ownerPackageFor(String repoRoot, File file) {
  final relative = relativeTo(file.path, repoRoot);
  final parts = relative.split('/');
  if (parts.length >= 3 && (parts.first == 'packages' || parts.first == 'apps')) {
    return parts[1];
  }
  throw StateError('Cannot determine owner package for $relative');
}

String relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}

/// The keys declared directly under a top-level pubspec [heading], at whatever
/// indentation that block happens to use.
///
/// YAML fixes no indent width, so a pubspec that indents its blocks deeper than
/// two spaces is valid and resolves like any other. Reading only two-space keys
/// hands the caller an empty set, and a gate that decides from that set reports
/// compliance it never checked - which is why a block with content it cannot
/// parse fails here instead of returning nothing.
///
/// The block's own indent is taken from its first entry; deeper lines are that
/// entry's children, and anything at column 0 ends the block.
/// [source] with comments and string literals blanked out, newlines preserved.
///
/// A gate that decides from a substring match must not read a mention as
/// handling: an enum value named in a doc comment or in an error message says
/// nothing about whether any code branches on it.
///
/// `dartclaw_workflow`'s shape suite carries an equivalent stripper. This suite
/// cannot share it — `fitness_suite_deps_test.dart` pins it free of any
/// `package:dartclaw*` import — so the copy is the price of that pin. A fix to
/// one belongs in both.
String withoutCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';

    if (char == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (char == '/' && next == '*') {
      out.write('  ');
      i += 2;
      while (i < source.length && !(source[i] == '*' && i + 1 < source.length && source[i + 1] == '/')) {
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < source.length) {
        out.write('  ');
        i += 2;
      }
      continue;
    }
    if (char == "'" || char == '"') {
      final triple = i + 2 < source.length && source[i + 1] == char && source[i + 2] == char;
      final quote = triple ? char * 3 : char;
      out.write(' ' * quote.length);
      i += quote.length;
      while (i < source.length) {
        if (source[i] == r'\') {
          out.write('  ');
          i += 2;
          continue;
        }
        if (source.startsWith(quote, i)) {
          out.write(' ' * quote.length);
          i += quote.length;
          break;
        }
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    out.write(char);
    i++;
  }
  return out.toString();
}

/// Splits [source] on commas that sit outside any bracket pair.
///
/// An enhanced enum value may carry a constructor call, so a plain `split(',')`
/// would read each argument as another value.
List<String> splitTopLevelCommas(String source) {
  const openers = {'(': ')', '[': ']', '{': '}', '<': '>'};
  final parts = <String>[];
  final buffer = StringBuffer();
  final stack = <String>[];
  for (final char in source.split('')) {
    if (openers.containsKey(char)) {
      stack.add(openers[char]!);
    } else if (stack.isNotEmpty && stack.last == char) {
      stack.removeLast();
    } else if (char == ',' && stack.isEmpty) {
      parts.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  parts.add(buffer.toString());
  return parts;
}

/// The values [enumName] declares in [declarationPath], read from the
/// declaration itself.
///
/// A gate that carries its own copy of an enum's values is a gate that stops
/// noticing the value added next: the copy still passes while the consumer it
/// guards has an unhandled case.
Set<String> enumValuesIn(String repoRoot, String declarationPath, String enumName) {
  final file = File('$repoRoot/$declarationPath');
  if (!file.existsSync()) fail('$declarationPath does not exist, so enum $enumName cannot be read');
  final source = withoutCommentsAndStrings(file.readAsStringSync());
  final header = RegExp('\\benum\\s+$enumName\\b[^{]*\\{').firstMatch(source);
  if (header == null) fail('$declarationPath declares no enum $enumName');
  final body = source.substring(header.end);
  // An enhanced enum ends its value list at the first `;`; a plain one at `}`.
  final semicolon = body.indexOf(';');
  final brace = body.indexOf('}');
  final end = semicolon >= 0 && (brace < 0 || semicolon < brace) ? semicolon : brace;
  if (end < 0) fail('$declarationPath: enum $enumName has no closing body');
  final values = {
    for (final part in splitTopLevelCommas(body.substring(0, end)))
      if (RegExp(r'^\s*([a-z_]\w*)').firstMatch(part) case final match?) match.group(1)!,
  };
  if (values.isEmpty) fail('$declarationPath: no values parsed out of enum $enumName');
  return values;
}

Set<String> topLevelKeysInBlock(List<String> lines, String heading) {
  final keys = <String>{};
  var inBlock = false;
  var sawEntry = false;
  int? blockIndent;
  for (final line in lines) {
    if (!line.startsWith(' ') && line.trim() == heading) {
      inBlock = true;
      continue;
    }
    if (!inBlock) continue;
    if (line.isNotEmpty && !line.startsWith(' ')) break;
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    blockIndent ??= indent;
    if (indent < blockIndent) break;
    sawEntry = true;
    if (indent > blockIndent) continue;
    final match = RegExp(r'^([a-zA-Z_][a-zA-Z0-9_]*):').firstMatch(stripped);
    if (match != null) keys.add(match.group(1)!);
  }
  if (sawEntry && keys.isEmpty) {
    fail(
      'Block "$heading" has entries but none parsed as a key. The block parser did not read this pubspec, '
      'so any gate deciding from its result would pass without checking anything.',
    );
  }
  return keys;
}

Future<List<Map<String, dynamic>>> resolvedPubPackages(String workingDirectory) async {
  final result = await Process.run('dart', const ['pub', 'deps', '--json'], workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('dart pub deps --json failed: ${(result.stderr as String).trim()}');
  }

  final decoded = jsonDecode(result.stdout as String);
  if (decoded is! Map<String, dynamic> || decoded['packages'] is! List<dynamic>) {
    fail('dart pub deps --json returned a malformed package graph');
  }

  return [
    for (final package in decoded['packages'] as List<dynamic>)
      if (package is Map<String, dynamic>) package else fail('dart pub deps --json returned a malformed package entry'),
  ];
}

Future<({Set<String> dependencies, Set<String> devDependencies})> resolvedPackageDependencyShape(
  String workingDirectory,
  String packageName,
) async {
  final packages = await resolvedPubPackages(workingDirectory);
  final matches = packages.where((package) => package['name'] == packageName).toList();
  if (matches.length != 1) {
    fail('dart pub deps --json returned ${matches.length} entries for $packageName');
  }

  Set<String> dependencyNames(String field) {
    final value = matches.single[field];
    if (value is! List<dynamic> || value.any((dependency) => dependency is! String)) {
      fail('dart pub deps --json returned a malformed $field list for $packageName');
    }
    return value.cast<String>().toSet();
  }

  return (dependencies: dependencyNames('directDependencies'), devDependencies: dependencyNames('devDependencies'));
}
