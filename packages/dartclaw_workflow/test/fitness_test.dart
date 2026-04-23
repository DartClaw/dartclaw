import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fitness_support.dart';

void main() {
  final repoRoot = resolveRepoRoot();
  final baseline = loadBaseline(repoRoot);
  final snapshot = collectFitnessSnapshot(repoRoot);

  group('Fitness - size', () {
    test('F-SIZE-1: max 800 LOC per file (frozen allow-list)', () {
      final allowlist = baseline.allowlist['F-SIZE-1'] ?? const <String, Object?>{};
      final violations = <String>[];
      for (final entry in snapshot.fileLoc.entries) {
        final ceiling = (allowlist[entry.key] as num?)?.toInt() ?? workflowFitnessThreshold;
        final message = sizeViolationMessage(entry.key, entry.value, ceiling);
        if (message != null) violations.add(message);
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('Fitness - coupling', () {
    test('F-COUPLE-1: dartclaw_workflow imports no dartclaw_server', () {
      final offenders = <String>[];
      final workflowDir = Directory(p.join(repoRoot, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow'));
      for (final file in workflowDir.listSync(recursive: true, followLinks: false).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final relative = p.relative(file.path, from: repoRoot);
        final lines = file.readAsLinesSync();
        for (final line in lines) {
          if (line.contains("import 'package:dartclaw_server")) {
            offenders.add(relative);
            break;
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('F-COUPLE-2: no dart:io Process APIs in lib/src/workflow/ outside *_runner.dart', () {
      final offenders = <String>[];
      final workflowDir = Directory(p.join(repoRoot, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow'));
      final processApiPattern = RegExp(r'\b(?:Process(?:\.|Result\b)|SafeProcess\.)');
      for (final file in workflowDir.listSync(recursive: true, followLinks: false).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final relative = p.relative(file.path, from: repoRoot);
        if (p.basename(file.path).endsWith('_runner.dart')) continue;
        final source = sanitizeDartSourceForFitness(file.readAsStringSync());
        if (processApiPattern.hasMatch(source)) {
          offenders.add(relative);
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('F-COUPLE-3: dartclaw_server/task imports only dartclaw_workflow umbrella', () {
      final offenders = <String>[];
      final taskDir = Directory(p.join(repoRoot, 'packages', 'dartclaw_server', 'lib', 'src', 'task'));
      for (final file in taskDir.listSync(recursive: true, followLinks: false).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final relative = p.relative(file.path, from: repoRoot);
        final lines = file.readAsLinesSync();
        for (final line in lines) {
          if (line.contains("import 'package:dartclaw_workflow/src/")) {
            offenders.add(relative);
            break;
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });

  group('Fitness - contract', () {
    test('F-CONTRACT-1: inter-package config keys defined in workflow_task_config.dart', () {
      final allowlist = baseline.allowlist['F-CONTRACT-1'] ?? const <String, Object?>{};
      final taskFiles = snapshot.contractKeysByFile.entries.where(
        (entry) => entry.key.startsWith('packages/dartclaw_server/lib/src/task/'),
      );
      final failures = <String>[];
      for (final entry in taskFiles) {
        final allowed = ((allowlist[entry.key] as List?) ?? const <Object?>[]).map((value) => '$value').toSet();
        final unexpected = entry.value.difference(allowed);
        if (unexpected.isNotEmpty) {
          failures.add('${entry.key}: unexpected contract keys ${unexpected.toList()..sort()}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  });

  group('Fitness - class shape', () {
    test('F-CLASS-1: max 25 methods per class', () {
      final allowlist = baseline.allowlist['F-CLASS-1'] ?? const <String, Object?>{};
      final violations = <String>[];
      for (final entry in snapshot.classMethodCounts.entries) {
        final ceiling = (allowlist[entry.key] as num?)?.toInt() ?? classMethodThreshold;
        if (entry.value > ceiling) {
          violations.add('${entry.key} has ${entry.value} methods; allow-list ceiling is $ceiling.');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('F-CLASS-2: max 40 methods per file', () {
      final allowlist = baseline.allowlist['F-CLASS-2'] ?? const <String, Object?>{};
      final violations = <String>[];
      for (final entry in snapshot.fileMethodCounts.entries) {
        final ceiling = (allowlist[entry.key] as num?)?.toInt() ?? fileMethodThreshold;
        if (entry.value > ceiling) {
          violations.add('${entry.key} has ${entry.value} methods; allow-list ceiling is $ceiling.');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('F-COMPLEX-1: cyclomatic complexity <= 15 per method', () {
      final allowlist = baseline.allowlist['F-COMPLEX-1'] ?? const <String, Object?>{};
      final violations = <String>[];
      for (final entry in snapshot.methodComplexities.entries) {
        final ceiling = (allowlist[entry.key] as num?)?.toInt() ?? methodComplexityThreshold;
        if (entry.value > ceiling) {
          violations.add('${entry.key} complexity is ${entry.value}; allow-list ceiling is $ceiling.');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('Fitness - test coverage', () {
    test('F-TEST-1: scenarios/ contains >= 1 file per canonical workflow shape', () {
      expect(snapshot.scenarioFiles.length, greaterThanOrEqualTo(9));
      final missing = requiredScenarioTypes.difference(snapshot.scenarioTypes).toList()..sort();
      expect(missing, isEmpty, reason: 'Missing scenario types: $missing');
    });

    test('F-TEST-2: scenario tests do not import dart:io or spawn Process', () {
      final failures = <String>[];
      for (final relative in snapshot.scenarioFiles) {
        final source = File(p.join(repoRoot, relative)).readAsStringSync();
        if (source.contains("import 'dart:io'")) {
          failures.add('$relative imports dart:io');
        }
        if (RegExp(r'\bProcess(?:\.|\()').hasMatch(source)) {
          failures.add('$relative spawns or references Process');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  });

  group('Decomposition triggers', () {
    test('trigger: no file > 5,500 LOC', () {
      final violations = snapshot.fileLoc.entries
          .where((entry) => entry.value > workflowExecutorDecompositionTrigger)
          .map((entry) => '${entry.key} is ${entry.value} LOC')
          .toList();
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('trigger: no new _dartclaw.internal.* sentinel keys', () {
      final sentinelMatches = <String>[];
      for (final entry in snapshot.contractKeysByFile.entries) {
        final sentinels = entry.value.where((key) => key.startsWith('_dartclaw.internal')).toList();
        if (sentinels.isNotEmpty) {
          sentinelMatches.add('${entry.key}: $sentinels');
        }
      }
      expect(sentinelMatches, isEmpty, reason: sentinelMatches.join('\n'));
    });

    test('trigger: workflow_executor test-to-source ratio >= 0.3', () {
      final sourcePath = p.join(repoRoot, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'workflow_executor.dart');
      final testPath = p.join(repoRoot, 'packages', 'dartclaw_workflow', 'test', 'workflow', 'workflow_executor_test.dart');
      final sourceLines = File(sourcePath).readAsLinesSync().length;
      final testLines = File(testPath).readAsLinesSync().length;
      final ratio = testLines / sourceLines;
      expect(ratio, greaterThanOrEqualTo(0.3), reason: 'workflow_executor test/source ratio is ${ratio.toStringAsFixed(2)}');
    });
  });
}
