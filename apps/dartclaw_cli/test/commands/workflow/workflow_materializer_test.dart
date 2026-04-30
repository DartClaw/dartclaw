import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow_materializer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _workflowDefinitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow definitions dir');
    }
    current = parent;
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('workflow_materializer_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('materializes three workflow yaml files into an empty workspace and skips them on the second run', () async {
    final copied = await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: _workflowDefinitionsDir());

    expect(copied, 3);

    final targetDir = Directory(p.join(tempDir.path, 'workflows', 'definitions'));
    expect(targetDir.existsSync(), isTrue);
    final names =
        targetDir
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.yaml'))
            .map((file) => p.basename(file.path))
            .toList()
          ..sort();
    expect(names, equals(['code-review.yaml', 'plan-and-implement.yaml', 'spec-and-implement.yaml']));

    final copiedAgain = await WorkflowMaterializer.materialize(
      dataDir: tempDir.path,
      sourceDir: _workflowDefinitionsDir(),
    );
    expect(copiedAgain, 0);
  });

  test('does not overwrite a pre-existing workflow file', () async {
    final targetDir = Directory(p.join(tempDir.path, 'workflows', 'definitions'))..createSync(recursive: true);
    final existingFile = File(p.join(targetDir.path, 'code-review.yaml'));
    existingFile.writeAsStringSync('name: code-review\ndescription: local override\n');

    final copied = await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: _workflowDefinitionsDir());

    expect(copied, 2);
    expect(existingFile.readAsStringSync(), 'name: code-review\ndescription: local override\n');
  });

  test('updates a managed workflow file when the built-in source changes', () async {
    await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: _workflowDefinitionsDir());

    final sourceDir = Directory.systemTemp.createTempSync('workflow_materializer_source_');
    addTearDown(() {
      if (sourceDir.existsSync()) {
        sourceDir.deleteSync(recursive: true);
      }
    });

    for (final name in ['code-review.yaml', 'plan-and-implement.yaml', 'spec-and-implement.yaml']) {
      final sourcePath = p.join(_workflowDefinitionsDir(), name);
      File(sourcePath).copySync(p.join(sourceDir.path, name));
    }

    final updatedSource = File(p.join(sourceDir.path, 'code-review.yaml'));
    updatedSource.writeAsStringSync('name: code-review\ndescription: refreshed built-in\n');

    final copied = await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: sourceDir.path);

    expect(copied, 1);
    final targetFile = File(p.join(tempDir.path, 'workflows', 'definitions', 'code-review.yaml'));
    expect(targetFile.readAsStringSync(), contains('refreshed built-in'));
  });

  test('preserves locally modified managed workflow files', () async {
    await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: _workflowDefinitionsDir());

    final targetFile = File(p.join(tempDir.path, 'workflows', 'definitions', 'code-review.yaml'));
    targetFile.writeAsStringSync('name: code-review\ndescription: locally edited managed copy\n');

    final sourceDir = Directory.systemTemp.createTempSync('workflow_materializer_source_');
    addTearDown(() {
      if (sourceDir.existsSync()) {
        sourceDir.deleteSync(recursive: true);
      }
    });

    for (final name in ['code-review.yaml', 'plan-and-implement.yaml', 'spec-and-implement.yaml']) {
      final sourcePath = p.join(_workflowDefinitionsDir(), name);
      File(sourcePath).copySync(p.join(sourceDir.path, name));
    }

    File(
      p.join(sourceDir.path, 'code-review.yaml'),
    ).writeAsStringSync('name: code-review\ndescription: upstream built-in update\n');

    final copied = await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: sourceDir.path);

    expect(copied, 0);
    expect(targetFile.readAsStringSync(), contains('locally edited managed copy'));
  });

  test('removes a stale managed workflow file that no longer exists upstream', () async {
    await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: _workflowDefinitionsDir());

    // Create a reduced source dir that omits code-review.yaml
    final sourceDir = Directory.systemTemp.createTempSync('workflow_materializer_source_');
    addTearDown(() {
      if (sourceDir.existsSync()) {
        sourceDir.deleteSync(recursive: true);
      }
    });

    for (final name in ['plan-and-implement.yaml', 'spec-and-implement.yaml']) {
      File(p.join(_workflowDefinitionsDir(), name)).copySync(p.join(sourceDir.path, name));
    }

    final staleFile = File(p.join(tempDir.path, 'workflows', 'definitions', 'code-review.yaml'));
    expect(staleFile.existsSync(), isTrue, reason: 'code-review.yaml should exist before cleanup');

    final copied = await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: sourceDir.path);

    expect(copied, 0);
    expect(staleFile.existsSync(), isFalse, reason: 'stale managed file should be removed');
    expect(
      File('${staleFile.path}.dartclaw-managed.json').existsSync(),
      isFalse,
      reason: 'marker file should also be removed',
    );
  });

  test('preserves a stale managed workflow file that has local edits', () async {
    await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: _workflowDefinitionsDir());

    // Locally edit the managed file before it becomes stale
    final targetFile = File(p.join(tempDir.path, 'workflows', 'definitions', 'code-review.yaml'));
    targetFile.writeAsStringSync('name: code-review\ndescription: locally edited\n');

    // Create a reduced source dir that omits code-review.yaml
    final sourceDir = Directory.systemTemp.createTempSync('workflow_materializer_source_');
    addTearDown(() {
      if (sourceDir.existsSync()) {
        sourceDir.deleteSync(recursive: true);
      }
    });

    for (final name in ['plan-and-implement.yaml', 'spec-and-implement.yaml']) {
      File(p.join(_workflowDefinitionsDir(), name)).copySync(p.join(sourceDir.path, name));
    }

    final copied = await WorkflowMaterializer.materialize(dataDir: tempDir.path, sourceDir: sourceDir.path);

    expect(copied, 0);
    expect(targetFile.existsSync(), isTrue, reason: 'locally edited stale file should be preserved');
    expect(targetFile.readAsStringSync(), contains('locally edited'));
  });
}
