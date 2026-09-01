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

Set<String> topLevelKeysInBlock(List<String> lines, String heading) {
  final keys = <String>{};
  var inBlock = false;
  for (final line in lines) {
    if (!line.startsWith(' ') && line.trim() == heading) {
      inBlock = true;
      continue;
    }
    if (inBlock && line.isNotEmpty && !line.startsWith(' ')) {
      break;
    }
    if (!inBlock || !line.startsWith('  ') || line.startsWith('    ')) continue;
    final match = RegExp(r'^\s{2}([a-zA-Z_][a-zA-Z0-9_]*):').firstMatch(line);
    if (match != null) keys.add(match.group(1)!);
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
