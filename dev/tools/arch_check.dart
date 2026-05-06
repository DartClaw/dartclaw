import 'dart:convert';
import 'dart:io';

// Ratchet: this bound is a soft architectural nag, not a hard limit. The intent
// is to keep `dartclaw_core/lib` focused on runtime primitives; non-primitive
// growth should land in `dartclaw_models` / `dartclaw_config` instead. Bump
// only with a CHANGELOG note explaining what justified the growth — the
// conversation forced by every breach is the point.
const _coreLocCeiling = 13000;
const _barrelExportCeiling = 81;
const _workspacePackageCeiling = 14;
const _workspaceAppNames = {'dartclaw_cli'};
const _expectedWorkspaceDependencies = <String, Set<String>>{
  'dartclaw': {'dartclaw_core', 'dartclaw_google_chat', 'dartclaw_signal', 'dartclaw_storage', 'dartclaw_whatsapp'},
  'dartclaw_cli': {
    'dartclaw_config',
    'dartclaw_core',
    'dartclaw_google_chat',
    'dartclaw_security',
    'dartclaw_server',
    'dartclaw_signal',
    'dartclaw_storage',
    'dartclaw_whatsapp',
    'dartclaw_workflow',
  },
  'dartclaw_config': {'dartclaw_models', 'dartclaw_security'},
  'dartclaw_core': {'dartclaw_config', 'dartclaw_models', 'dartclaw_security'},
  'dartclaw_google_chat': {'dartclaw_config', 'dartclaw_core'},
  'dartclaw_models': {},
  'dartclaw_security': {'dartclaw_models'},
  'dartclaw_server': {
    'dartclaw_config',
    'dartclaw_core',
    'dartclaw_google_chat',
    'dartclaw_models',
    'dartclaw_security',
    'dartclaw_signal',
    'dartclaw_storage',
    'dartclaw_whatsapp',
    'dartclaw_workflow',
  },
  'dartclaw_signal': {'dartclaw_config', 'dartclaw_core'},
  'dartclaw_storage': {'dartclaw_core'},
  'dartclaw_testing': {
    'dartclaw_core',
    'dartclaw_google_chat',
    'dartclaw_models',
    'dartclaw_security',
    'dartclaw_server',
    'dartclaw_workflow',
  },
  'dartclaw_whatsapp': {'dartclaw_config', 'dartclaw_core'},
  'dartclaw_workflow': {'dartclaw_config', 'dartclaw_core', 'dartclaw_models', 'dartclaw_security'},
};

final class _CheckResult {
  final String name;
  final bool passed;
  final String detail;

  const _CheckResult({required this.name, required this.passed, required this.detail});
}

Future<void> main() async {
  final scriptPath = File.fromUri(Platform.script).resolveSymbolicLinksSync();
  final repoRoot = File(scriptPath).parent.parent.parent.path;
  final results = <_CheckResult>[
    await _checkDependencyGraph(repoRoot),
    _checkCoreSqliteDependency(repoRoot),
    _checkCrossPackageSrcImports(repoRoot),
    _checkCoreLoc(repoRoot),
    _checkBarrelExports(repoRoot),
    _checkWorkspacePackageCount(repoRoot),
  ];

  var failures = 0;
  for (final result in results) {
    final status = result.passed ? 'PASS' : 'FAIL';
    stdout.writeln('$status ${result.name}: ${result.detail}');
    if (!result.passed) {
      failures += 1;
    }
  }

  stdout.writeln();
  if (failures == 0) {
    stdout.writeln('PASS summary: ${results.length}/${results.length} checks passed.');
    exitCode = 0;
    return;
  }

  stdout.writeln('FAIL summary: $failures/${results.length} checks failed.');
  exitCode = 1;
}

Future<_CheckResult> _checkDependencyGraph(String repoRoot) async {
  final result = await Process.run('dart', const ['pub', 'deps', '--json'], workingDirectory: repoRoot);

  if (result.exitCode != 0) {
    final stderr = (result.stderr as String).trim();
    return _CheckResult(
      name: 'L1 dependency graph & layering',
      passed: false,
      detail: 'dart pub deps --json failed: ${stderr.isEmpty ? 'unknown error' : stderr}',
    );
  }

  try {
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map<String, dynamic>) {
      return const _CheckResult(
        name: 'L1 dependency graph & layering',
        passed: false,
        detail: 'dart pub deps --json returned a non-object payload.',
      );
    }

    final packages = decoded['packages'];
    final packageCount = packages is List ? packages.length : 0;
    final workspaceMembers = _workspaceMembers(repoRoot);
    final layerViolations = <String>[];
    for (final member in workspaceMembers) {
      final expectedDeps = _expectedWorkspaceDependencies[member.name];
      if (expectedDeps == null) {
        layerViolations.add('${member.name}: no expected dependency contract defined');
        continue;
      }

      final actualDeps = _workspaceDependencyNames(member);
      final missingDeps = expectedDeps.difference(actualDeps).toList()..sort();
      final unexpectedDeps = actualDeps.difference(expectedDeps).toList()..sort();

      if (missingDeps.isNotEmpty || unexpectedDeps.isNotEmpty) {
        final parts = <String>[];
        if (missingDeps.isNotEmpty) {
          parts.add('missing ${missingDeps.join(', ')}');
        }
        if (unexpectedDeps.isNotEmpty) {
          parts.add('unexpected ${unexpectedDeps.join(', ')}');
        }
        layerViolations.add('${member.name}: ${parts.join('; ')}');
      }
    }

    final coreBarrel = File('$repoRoot/packages/dartclaw_core/lib/dartclaw_core.dart');
    if (coreBarrel.existsSync() &&
        RegExp(
          r'''^\s*export\s+['"]package:dartclaw_config/dartclaw_config\.dart['"]''',
          multiLine: true,
        ).hasMatch(coreBarrel.readAsStringSync())) {
      layerViolations.add('dartclaw_core: barrel must not re-export package:dartclaw_config/dartclaw_config.dart');
    }

    if (layerViolations.isNotEmpty) {
      return _CheckResult(
        name: 'L1 dependency graph & layering',
        passed: false,
        detail:
            'dart pub deps --json succeeded but found ${layerViolations.length} layering violation(s): '
            '${layerViolations.take(4).join(', ')}${layerViolations.length > 4 ? ' ...' : ''}',
      );
    }

    return _CheckResult(
      name: 'L1 dependency graph & layering',
      passed: true,
      detail:
          'dart pub deps --json succeeded; workspace graph resolved with $packageCount package entries and all '
          '${workspaceMembers.length} workspace members match the documented internal dependency DAG.',
    );
  } catch (error) {
    return _CheckResult(
      name: 'L1 dependency graph & layering',
      passed: false,
      detail: 'Could not parse dart pub deps --json output: $error',
    );
  }
}

_CheckResult _checkCoreSqliteDependency(String repoRoot) {
  final pubspec = File('$repoRoot/packages/dartclaw_core/pubspec.yaml').readAsStringSync();
  final dependenciesSection = _topLevelSection(pubspec, 'dependencies');
  final hasSqlite = RegExp(r'^\s{2}sqlite3\s*:', multiLine: true).hasMatch(dependenciesSection);
  return _CheckResult(
    name: 'L1 core sqlite3 boundary',
    passed: !hasSqlite,
    detail: hasSqlite
        ? 'packages/dartclaw_core/pubspec.yaml declares sqlite3 in production dependencies.'
        : 'packages/dartclaw_core/pubspec.yaml has no sqlite3 production dependency.',
  );
}

_CheckResult _checkCrossPackageSrcImports(String repoRoot) {
  final violations = <String>[];
  for (final member in _workspaceMembers(repoRoot)) {
    final libDir = Directory('${member.path}${Platform.pathSeparator}lib');
    if (!libDir.existsSync()) {
      continue;
    }

    for (final file in libDir.listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }

      final relativePath = _relativePath(file.path, repoRoot);
      final content = file.readAsStringSync();
      for (final match in RegExp(r'''import\s+['"]package:([^/'"]+)/src/[^'"]+['"]''').allMatches(content)) {
        final importedPackage = match.group(1);
        if (importedPackage == null || importedPackage == member.name) {
          continue;
        }
        violations.add('$relativePath -> package:$importedPackage/src/');
      }
    }
  }

  return _CheckResult(
    name: 'L1 no cross-package src imports',
    passed: violations.isEmpty,
    detail: violations.isEmpty
        ? 'No production library imports cross into another package\'s src/.'
        : 'Found ${violations.length} violating import(s): ${violations.take(5).join(', ')}'
              '${violations.length > 5 ? ' ...' : ''}',
  );
}

_CheckResult _checkCoreLoc(String repoRoot) {
  final libDir = Directory('$repoRoot/packages/dartclaw_core/lib');
  var loc = 0;
  for (final file in libDir.listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.dart')) {
      continue;
    }
    loc += file.readAsLinesSync().length;
  }

  return _CheckResult(
    name: 'L2 core LOC ceiling',
    passed: loc <= _coreLocCeiling,
    detail: '$loc lines in packages/dartclaw_core/lib (threshold <= $_coreLocCeiling).',
  );
}

_CheckResult _checkBarrelExports(String repoRoot) {
  var maxExports = 0;
  var maxPackage = '';
  final offenders = <String>[];

  for (final member in _packageMembers(repoRoot)) {
    final barrel = File('${member.path}${Platform.pathSeparator}lib${Platform.pathSeparator}${member.name}.dart');
    if (!barrel.existsSync()) {
      continue;
    }

    final exportCount = RegExp(r'^\s*export\s+', multiLine: true).allMatches(barrel.readAsStringSync()).length;
    if (exportCount > maxExports) {
      maxExports = exportCount;
      maxPackage = member.name;
    }
    if (exportCount > _barrelExportCeiling) {
      offenders.add('${member.name}=$exportCount');
    }
  }

  return _CheckResult(
    name: 'L2 barrel export ceiling',
    passed: offenders.isEmpty,
    detail: offenders.isEmpty
        ? 'Max barrel export count is $maxExports in $maxPackage (threshold <= $_barrelExportCeiling).'
        : 'Barrels above threshold: ${offenders.join(', ')}.',
  );
}

_CheckResult _checkWorkspacePackageCount(String repoRoot) {
  final packageCount = _packageMembers(repoRoot).length;
  return _CheckResult(
    name: 'L2 workspace package count',
    passed: packageCount <= _workspacePackageCeiling,
    detail: '$packageCount packages under packages/ (threshold <= $_workspacePackageCeiling).',
  );
}

List<_WorkspaceMember> _workspaceMembers(String repoRoot) {
  return [
    ..._packageMembers(repoRoot),
    ...Directory(
      '$repoRoot/apps',
    ).listSync().whereType<Directory>().map((dir) => _WorkspaceMember(name: _basename(dir.path), path: dir.path)),
  ];
}

List<_WorkspaceMember> _packageMembers(String repoRoot) {
  return Directory('$repoRoot/packages')
      .listSync()
      .whereType<Directory>()
      .map((dir) => _WorkspaceMember(name: _basename(dir.path), path: dir.path))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
}

String _topLevelSection(String yaml, String sectionName) {
  final lines = const LineSplitter().convert(yaml);
  final buffer = StringBuffer();
  var inSection = false;
  for (final line in lines) {
    final isTopLevel = !line.startsWith(' ') && line.contains(':');
    if (isTopLevel) {
      if (line.startsWith('$sectionName:')) {
        inSection = true;
        buffer.writeln(line);
        continue;
      }
      if (inSection) {
        break;
      }
    }
    if (inSection) {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}

Set<String> _workspaceDependencyNames(_WorkspaceMember member) {
  final pubspec = File('${member.path}${Platform.pathSeparator}pubspec.yaml');
  if (!pubspec.existsSync()) {
    return const <String>{};
  }

  final dependenciesSection = _topLevelSection(pubspec.readAsStringSync(), 'dependencies');
  final dependencyNames = _topLevelKeys(dependenciesSection);
  return dependencyNames.where(_isWorkspaceDependencyName).toSet();
}

List<String> _topLevelKeys(String yamlSection) {
  final keys = <String>[];
  for (final line in const LineSplitter().convert(yamlSection)) {
    if (_indentWidth(line) != 2) {
      continue;
    }

    final colonIndex = line.indexOf(':');
    if (colonIndex <= 0) {
      continue;
    }

    final key = line.substring(2, colonIndex).trim();
    if (key.isNotEmpty) {
      keys.add(key);
    }
  }
  return keys;
}

bool _isWorkspaceDependencyName(String name) =>
    name.startsWith('dartclaw_') || name == 'dartclaw' || _workspaceAppNames.contains(name);

int _indentWidth(String line) => line.length - line.trimLeft().length;

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.split('/').where((segment) => segment.isNotEmpty).last;
}

String _relativePath(String path, String repoRoot) {
  final normalizedPath = path.replaceAll('\\', '/');
  final normalizedRoot = repoRoot.replaceAll('\\', '/');
  if (normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath.substring(normalizedRoot.length + 1);
  }
  return normalizedPath;
}

final class _WorkspaceMember {
  final String name;
  final String path;

  const _WorkspaceMember({required this.name, required this.path});
}
